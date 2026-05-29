---
content_hash: sha256:53d399c35eda9d79748651c9d35746444aba28fc2667e3e4b15d6691ae9df544
crawled_at: '2026-05-28T18:54:24.538632+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_depth.html
tags:
- bitunix-api-future
- web-docs
title: Get Depth | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_depth.html#VPContent)
Menu
Return to top
# Get Depth [​](https://www.bitunix.com/api-docs/futures/market/get_depth.html#get-depth)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_depth.html#description)
Interface is used to get future order book.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_depth.html#http-request)
  * GET /api/v1/futures/market/depth

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_depth.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair, based on the symbolName, i.e. BTCUSDT  |
| limit  | string  | false  | Fixed gear enumeration value: 1/5/15/50/max, passing max returns the maximum gear of the trading pairWhen the actual depth does not meet the limit, return according to the actual gear . If max is passed in, the maximum level of the trading pair will be returned.  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/depth?symbol=BTCUSDT&limit=max'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_depth.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| asks.index[0]  | string  | ask price  |
| asks.index[1]  | string  | ask amount  |
| bids.index[0]  | string  | bid price  |
| bids.index[1]  | string  | bid amount  |
Response Example
json
```
{"code":0,"data":{"asks":[[0.1001,0.1],[0.1002,10]],"bids":[[0.1,1],[0.0999,10.23]]},"msg":"Success"}
```