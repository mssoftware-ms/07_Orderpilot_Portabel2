---
content_hash: sha256:218cf8cde078d5ec692d13708226d91a31cb8f892c4191e7e9c917c197516e18
crawled_at: '2026-05-28T18:54:24.580270+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html
tags:
- bitunix-api-future
- web-docs
title: Get Funding Rate | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html#VPContent)
Menu
Return to top
# Get Funding Rate [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html#get-funding-rate)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html#description)
Get the current funding rate of the contract
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html#http-request)
  * GET /api/v1/futures/market/funding_rate/batch

Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/funding_rate/batch'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_funding_rate_batch.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| symbol  | string  | Coin pair  |
| markPrice  | decimal  | mark price  |
| lastPrice  | decimal  | last price  |
| fundingRate  | decimal  | Current funding rates  |
| nextFundingTime  | int64  | next Funding settlement time(ms)  |
| fundingInterval  | int32  | funding settlement interval(hour)  |
Response Example
json
```
{"code":0,"data":[{"symbol":"BTCUSDT","markPrice":"60000","lastPrice":"60001","fundingRate":"0.0005","fundingInterval":8,"nextFundingTime":"1770710400000"}],"msg":"Success"}
```