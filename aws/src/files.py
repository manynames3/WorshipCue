"""Private immutable S3 uploads, byte/hash verification, real PDF geometry."""
import base64
import hashlib
import io
import logging
import math
import struct
import zlib

from domain import APIError


def validate_pdf(data):
    try:
        from pypdf import PdfReader
        # Parser diagnostics can contain excerpts of private score bytes.
        # Suppress the library subtree before opening any uploaded document.
        for name in ['pypdf', *list(logging.Logger.manager.loggerDict)]:
            if name == 'pypdf' or name.startswith('pypdf.'):
                logger = logging.getLogger(name)
                logger.setLevel(logging.CRITICAL + 1)
                logger.propagate = False
                logger.handlers = [logging.NullHandler()]
        reader = PdfReader(io.BytesIO(data), strict=True)
        if reader.is_encrypted or not 0 < len(reader.pages) <= 20:
            raise ValueError('Unsupported PDF')
        pages = []
        for index, page in enumerate(reader.pages):
            media, crop = page.mediabox, page.cropbox
            rotation = int(page.rotation or 0) % 360
            unit = float(page.get('/UserUnit', 1))
            values = [float(v) * unit for v in (media.left, media.bottom, media.width,
                media.height, crop.left, crop.bottom, crop.width, crop.height)]
            if rotation not in (0, 90, 180, 270) or unit != 1 or not all(math.isfinite(v) for v in values):
                raise ValueError('Invalid geometry')
            if min(values[2:4] + values[6:8]) <= 0 or max(values[2:4] + values[6:8]) > 14400:
                raise ValueError('Invalid geometry')
            if values[4] < values[0] or values[5] < values[1] or values[4]+values[6] > values[0]+values[2]+0.01 or values[5]+values[7] > values[1]+values[3]+0.01:
                raise ValueError('CropBox outside MediaBox')
            pages.append({'schema_version':1,'crop_x':values[4],'crop_y':values[5],
                          'crop_width':values[6],'crop_height':values[7],'rotation':rotation})
        return {'page_manifest': pages, 'page_count': len(pages)}
    except ImportError:
        raise APIError('PDF_VALIDATOR_UNAVAILABLE', 503) from None
    except Exception:
        raise APIError('INVALID_PDF') from None


def validate_png(data):
    if not 57 <= len(data) <= 2097152 or data[:8] != b'\x89PNG\r\n\x1a\n':
        raise APIError('INVALID_PREVIEW')
    offset, width, height, compressed, ended, data_ended, chunks = 8, 0, 0, [], False, False, 0
    while offset + 12 <= len(data):
        size = int.from_bytes(data[offset:offset+4], 'big')
        kind, start = data[offset+4:offset+8], offset+8
        if len(kind) != 4 or not all(65 <= c <= 90 or 97 <= c <= 122 for c in kind):
            raise APIError('INVALID_PREVIEW')
        end = start+size
        chunks += 1
        if end+4 > len(data) or chunks > 1000 or zlib.crc32(data[offset+4:end]) != int.from_bytes(data[end:end+4], 'big'):
            raise APIError('INVALID_PREVIEW')
        if kind == b'IHDR':
            if offset != 8 or size != 13:
                raise APIError('INVALID_PREVIEW')
            width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', data[start:end])
            if not 0 < width <= 8192 or not 0 < height <= 8192 or width*height > 16777216 or (depth,color,comp,filt,interlace) != (8,6,0,0,0):
                raise APIError('INVALID_PREVIEW')
        elif kind == b'IDAT':
            if not width or data_ended:
                raise APIError('INVALID_PREVIEW')
            compressed.append(data[start:end])
        elif kind == b'IEND':
            if size or not compressed or end+4 != len(data):
                raise APIError('INVALID_PREVIEW')
            ended = True
        else:
            if kind == b'acTL' or (kind[:1].isupper() and kind != b'PLTE'):
                raise APIError('INVALID_PREVIEW')
            data_ended = bool(compressed)
        offset = end+4
    if not ended or offset != len(data):
        raise APIError('INVALID_PREVIEW')
    expected = height*(1+4*width)
    try:
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(b''.join(compressed), expected+1)
        if len(decoded) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or any(decoded[i*(1+4*width)] > 4 for i in range(height)):
            raise ValueError('Invalid pixels')
    except Exception:
        raise APIError('INVALID_PREVIEW') from None
    return {'kind': 'png-rgba', 'width': width, 'height': height}


class Files:
    def __init__(self, s3, bucket, domain):
        self.s3, self.bucket, self.domain = s3, bucket, domain

    def upload_url(self, body, actor):
        asset = self.domain.asset_for_key(actor, body.get('key'), upload=True)
        count, kind = asset['bytes'], asset['type']
        mime = {'pdf':'application/pdf', 'native':'application/octet-stream', 'preview':'image/png'}[kind]
        if body.get('bytes') != count or body.get('content_type') != mime:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        checksum = base64.b64encode(bytes.fromhex(asset['sha256'])).decode()
        params = {'Bucket':self.bucket, 'Key':asset['storage_key'], 'ContentType':mime,
                  'ChecksumSHA256':checksum, 'IfNoneMatch':'*', 'ContentLength':count}
        url = self.s3.generate_presigned_url('put_object', Params=params, ExpiresIn=120)
        return {'url':url, 'headers':{'Content-Type':mime, 'If-None-Match':'*',
                'x-amz-checksum-sha256':checksum}}

    def download_url(self, body, actor):
        asset = self.domain.asset_for_key(actor, body.get('key'))
        url = self.s3.generate_presigned_url('get_object', Params={'Bucket':self.bucket,
            'Key':asset['storage_key'], 'ResponseCacheControl':'private, max-age=0'}, ExpiresIn=60)
        return {'url':url}

    def finalize(self, body, actor):
        asset = self.domain.upload_asset(body.get('asset_id'), actor, allow_verified=True)
        if body.get('sha256') != asset['sha256'] or body.get('expected_bytes') != asset['bytes']:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        if asset['status'] == 'verified':
            return asset
        try:
            head = self.s3.head_object(Bucket=self.bucket, Key=asset['storage_key'], ChecksumMode='ENABLED')
        except Exception as error:
            response = getattr(error, 'response', {})
            if (isinstance(response, dict) and response.get('ResponseMetadata', {}).get('HTTPStatusCode') == 404
                    and response.get('Error', {}).get('Code') in ('404', 'NoSuchKey', 'NotFound')):
                raise APIError('FILE_NOT_READY', 404) from None
            raise
        count = asset['bytes']
        if head['ContentLength'] != count or count > (104857600 if asset['type']=='pdf' else 2097152):
            raise APIError('HASH_MISMATCH', 409)
        response = self.s3.get_object(Bucket=self.bucket, Key=asset['storage_key'])
        stream = response['Body']
        try:
            data = stream.read(count+1)
        finally:
            stream.close()
        if len(data) != count or hashlib.sha256(data).hexdigest() != asset['sha256']:
            raise APIError('HASH_MISMATCH', 409)
        validation = validate_pdf(data) if asset['type']=='pdf' else validate_png(data) if asset['type']=='preview' else {'kind':'pencilkit-bounded'}
        return self.domain.finalize_asset(asset['id'], actor, {'sha256':asset['sha256'], 'bytes':count, **validation})
