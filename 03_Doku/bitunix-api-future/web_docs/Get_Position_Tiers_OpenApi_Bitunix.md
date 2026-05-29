---
content_hash: sha256:81983f5e201391f71021e363ba92e9682be8e44d50b6cab63c458930c6864573
crawled_at: '2026-05-28T18:54:24.804952+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html
tags:
- bitunix-api-future
- web-docs
title: Get Position Tiers | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#VPContent)
Menu
Return to top
# Get Position Tiers [​](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#get-position-tiers)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#description)
Get Position Tiers
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#http-request)
  * GET /api/v1/futures/position/get_position_tiers

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/position/get_position_tiers?symbol=BTCUSDT'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/position/get_position_tiers.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| symbol  | string  | Trading pair  |
| level  | int32  | level  |
| startValue  | string  | Minimum value  |
| endValue  | string  | Maximum value  |
| leverage  | int32  | leverage  |
| maintenanceMarginRate  | string  | Maintenance margin rate: The margin amount corresponds to the position quantity tier. When the margin rate of a position is less than the maintenance margin rate, it will trigger a forced partial liquidation or full liquidation.  |
Response Example
json
```
{"code":0,"data":[{"symbol":"BTCUSDT","level":1,"startValue":"0","endValue":"50000","leverage":125,"maintenanceMarginRate":"0.004"},{"symbol":"BTCUSDT","level":2,"startValue":"50000","endValue":"200000","leverage":100,"maintenanceMarginRate":"0.005"}],"msg":"Success"}
```