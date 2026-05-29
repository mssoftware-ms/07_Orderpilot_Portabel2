---
content_hash: sha256:b0810ec85863ca7dde3c7cf5d13bf06d1fb396435a24256e091f9a3d5119f0e7
crawled_at: '2026-05-28T18:54:24.589184+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/change_leverage.html
tags:
- bitunix-api-future
- web-docs
title: Change Leverage | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#VPContent)
Menu
Return to top
# Change Leverage [​](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#change-leverage)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#description)
Adjust the leverage on the given symbol
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#http-request)
  * POST /api/v1/futures/account/change_leverage

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| marginCoin  | string  | true  | Margin coin  |
| symbol  | string  | true  | Trading pair  |
| leverage  | int  | true  | Leverage  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/account/change_leverage' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","leverage":12,"marginCoin":"USDT"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_leverage.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| marginCoin  | string  | Margin coin  |
| symbol  | string  | Trading pair  |
| leverage  | int  | Leverage  |
Response Example
json
```
{"code":0,"data":[{"marginCoin":"USDT","leverage":12,"symbol":"BTCUSDT"}],"msg":"Success"}
```