| Client | Operation | Configuration | Metric | N | Median | Min | Max |
|---|---|---|---|---:|---:|---:|---:|
| C | blob | mars=0 | download_MiB_per_sec | 5 | 236.490 | 204.238 | 245.534 |
| C | blob | mars=0 | upload_MiB_per_sec | 5 | 140.771 | 139.000 | 149.505 |
| C | blob | mars=1 | download_MiB_per_sec | 5 | 56.080 | 55.320 | 58.361 |
| C | blob | mars=1 | upload_MiB_per_sec | 5 | 53.215 | 51.605 | 56.860 |
| C | connect_close | mars=0 | ms_per_connection | 5 | 73.404 | 72.310 | 74.882 |
| C | connect_close | mars=1 | ms_per_connection | 5 | 73.376 | 72.043 | 74.545 |
| C | fetch | mars=0 encoding=UTF16 rowset=1 | rows_per_sec | 5 | 1,402,741.000 | 1,322,401.000 | 1,437,381.000 |
| C | fetch | mars=0 encoding=UTF16 rowset=256 | rows_per_sec | 5 | 285,361.000 | 275,773.000 | 305,751.000 |
| C | fetch | mars=0 encoding=UTF8 rowset=1 | rows_per_sec | 5 | 1,416,210.000 | 1,369,807.000 | 1,468,235.000 |
| C | fetch | mars=0 encoding=UTF8 rowset=256 | rows_per_sec | 5 | 279,544.000 | 256,957.000 | 306,817.000 |
| C | fetch | mars=1 encoding=UTF16 rowset=1 | rows_per_sec | 5 | 614,126.000 | 539,680.000 | 634,905.000 |
| C | fetch | mars=1 encoding=UTF16 rowset=256 | rows_per_sec | 5 | 285,975.000 | 269,997.000 | 303,499.000 |
| C | fetch | mars=1 encoding=UTF8 rowset=1 | rows_per_sec | 5 | 556,437.000 | 528,603.000 | 581,284.000 |
| C | fetch | mars=1 encoding=UTF8 rowset=256 | rows_per_sec | 5 | 306,668.000 | 264,559.000 | 310,800.000 |
| C | insert | mars=0 parameter_array=0 | ms | 5 | 216.575 | 212.891 | 291.137 |
| C | insert | mars=0 parameter_array=1 | ms | 5 | 8.131 | 7.857 | 10.348 |
| C | insert | mars=1 parameter_array=0 | ms | 5 | 250.423 | 219.379 | 310.610 |
| C | insert | mars=1 parameter_array=1 | ms | 5 | 10.460 | 9.040 | 10.904 |
| C | prepared_select | mars=0 | us_per_query | 5 | 232.880 | 202.830 | 255.955 |
| C | prepared_select | mars=1 | us_per_query | 5 | 245.225 | 214.890 | 253.230 |
| C | select1 | mars=0 | us_per_query | 5 | 313.715 | 302.760 | 347.315 |
| C | select1 | mars=1 | us_per_query | 5 | 332.280 | 248.160 | 435.400 |
| Haskell | blob | mars=0 | download_MiB_per_sec | 5 | 225.454 | 211.965 | 234.137 |
| Haskell | blob | mars=0 | upload_MiB_per_sec | 5 | 145.502 | 137.287 | 154.542 |
| Haskell | blob | mars=1 | download_MiB_per_sec | 5 | 58.017 | 55.280 | 61.118 |
| Haskell | blob | mars=1 | upload_MiB_per_sec | 5 | 55.564 | 52.074 | 59.412 |
| Haskell | connect_close | mars=0 | ms_per_connection | 5 | 71.114 | 71.035 | 71.548 |
| Haskell | connect_close | mars=1 | ms_per_connection | 5 | 71.583 | 70.632 | 74.631 |
| Haskell | fetch | mars=0 api=query | rows_per_sec | 5 | 336,759.000 | 313,933.000 | 342,570.000 |
| Haskell | fetch | mars=0 api=stream | rows_per_sec | 5 | 410,642.000 | 402,448.000 | 412,928.000 |
| Haskell | fetch | mars=1 api=query | rows_per_sec | 5 | 291,522.000 | 274,414.000 | 291,972.000 |
| Haskell | fetch | mars=1 api=stream | rows_per_sec | 5 | 330,604.000 | 328,835.000 | 332,485.000 |
| Haskell | select1 | mars=0 | us_per_query | 5 | 416.855 | 403.980 | 454.035 |
| Haskell | select1 | mars=1 | us_per_query | 5 | 339.505 | 325.240 | 400.485 |
