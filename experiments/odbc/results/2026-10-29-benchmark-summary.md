| Operation | Configuration | Metric | Rounds | Median | Min | Max |
|---|---|---|---:|---:|---:|---:|
| blob | mars=0 | download_MiB_per_sec | 5 | 231.294 | 222.482 | 235.696 |
| blob | mars=0 | upload_MiB_per_sec | 5 | 139.626 | 133.520 | 144.629 |
| blob | mars=1 | download_MiB_per_sec | 5 | 62.209 | 61.566 | 62.619 |
| blob | mars=1 | upload_MiB_per_sec | 5 | 58.603 | 58.365 | 59.790 |
| connect_close | mars=0 | ms_per_connection | 5 | 70.360 | 69.211 | 70.623 |
| connect_close | mars=1 | ms_per_connection | 5 | 70.574 | 70.157 | 81.429 |
| fetch | mars=0 encoding=UTF16 rowset=1 | rows_per_sec | 5 | 1,529,941.000 | 1,448,813.000 | 1,611,032.000 |
| fetch | mars=0 encoding=UTF16 rowset=256 | rows_per_sec | 5 | 327,665.000 | 319,754.000 | 330,865.000 |
| fetch | mars=0 encoding=UTF8 rowset=1 | rows_per_sec | 5 | 1,499,700.000 | 1,438,104.000 | 1,534,684.000 |
| fetch | mars=0 encoding=UTF8 rowset=256 | rows_per_sec | 5 | 326,096.000 | 315,169.000 | 332,877.000 |
| fetch | mars=1 encoding=UTF16 rowset=1 | rows_per_sec | 5 | 616,523.000 | 606,494.000 | 625,223.000 |
| fetch | mars=1 encoding=UTF16 rowset=256 | rows_per_sec | 5 | 309,825.000 | 298,220.000 | 316,463.000 |
| fetch | mars=1 encoding=UTF8 rowset=1 | rows_per_sec | 5 | 619,882.000 | 604,295.000 | 630,577.000 |
| fetch | mars=1 encoding=UTF8 rowset=256 | rows_per_sec | 5 | 307,142.000 | 299,900.000 | 314,534.000 |
| insert | mars=0 parameter_array=0 | ms | 5 | 233.072 | 229.677 | 238.898 |
| insert | mars=0 parameter_array=1 | ms | 5 | 8.179 | 7.977 | 8.590 |
| insert | mars=1 parameter_array=0 | ms | 5 | 225.430 | 209.628 | 237.258 |
| insert | mars=1 parameter_array=1 | ms | 5 | 9.252 | 8.762 | 9.495 |
| prepared_select | mars=0 | us_per_query | 5 | 198.370 | 197.865 | 202.025 |
| prepared_select | mars=1 | us_per_query | 5 | 198.575 | 196.910 | 200.965 |
| select1 | mars=0 | us_per_query | 5 | 287.980 | 283.260 | 315.340 |
| select1 | mars=1 | us_per_query | 5 | 270.570 | 269.715 | 275.175 |
