# AWS runtime dependency

The user approved **pypdf 6.19.0** on October 8, 2026 for server-side PDF validation. It is BSD-3-Clause licensed; the full license is retained in `THIRD_PARTY_LICENSES/pypdf-BSD-3-Clause.txt` and inside the deployment archive.

`requirements.txt` and `package_backend.py` pin the official pure-Python wheel by SHA-256. Python 3.13 needs no required additional dependency. No optional crypto, image, font or development extras are bundled. See the [official release metadata](https://pypi.org/project/pypdf/6.19.0/).

The finalizer checks source bytes, encryption, page count, CropBox/MediaBox geometry and rotations before permitting publication. It does not extract score text or transmit source material to another parser service. Library diagnostics are suppressed because malformed-file warnings can contain private source excerpts. The parser is bounded by 100 MiB upload size, twenty pages, Lambda memory/time limits and an HTTP timeout; representative maximum-sized files still need performance qualification.

AWS supplies boto3/botocore in its managed Lambda runtime. The application package adds no other runtime library. Native GRDB and the preserved Supabase implementation retain their existing dependency records.
