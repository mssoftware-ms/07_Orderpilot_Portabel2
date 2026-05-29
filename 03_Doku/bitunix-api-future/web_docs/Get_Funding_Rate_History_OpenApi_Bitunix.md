---
content_hash: sha256:4c01718e5be3629d01ccec70d437cbe0b8383883d4aae9aeeab5492f43151bde
crawled_at: '2026-05-28T18:54:24.666606+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html
tags:
- bitunix-api-future
- web-docs
title: Get Funding Rate History | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#VPContent)
Menu
Return to top
# Get Funding Rate [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#get-funding-rate)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#description)
Get the history funding rate of the contract
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#http-request)
  * GET /api/v1/futures/market/get_funding_rate_history

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair, based on the symbolName, i.e. BTCUSDT  |
| starTime  | int64  | false  | Start timestamp(Funding settle time)Unix timestamp in milliseconds format, e.g. 1597026383085  |
| endTime  | int64  | fasle  | End timestamp(Funding settle time)Unix timestamp in milliseconds format, e.g. 1597026383085  |
| limit  | int32  | false  | Default: 100,Maximum: 200  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/get_funding_rate_history?symbol=BTCUSDT&limit=10'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_history.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| markPrice  | string  | Mark price  |
| fundingRate  | string  | Funding rate  |
| fundingTime  | int64  | Funding timestamp  |
Response Example
json
```
{"code":0,"data":[{"fundingRate":"-0.00001191","fundingTime":"1772449200000","markPrice":"66286.6"}],"msg":"Success"}
```