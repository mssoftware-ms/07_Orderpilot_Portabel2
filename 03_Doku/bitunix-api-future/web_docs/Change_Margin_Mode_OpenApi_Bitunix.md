---
content_hash: sha256:c6e6ced30204f4231386ac6bcd2743c3e51de8d987dcece585256a0ebe2bc9d0
crawled_at: '2026-05-28T18:54:24.546904+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html
tags:
- bitunix-api-future
- web-docs
title: Change Margin Mode | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#VPContent)
Menu
Return to top
# Change Margin Mode [​](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#change-margin-mode)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#description)
This interface cannot be used when the users have an open position or an order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#http-request)
  * POST /api/v1/futures/account/change_margin_mode

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| marginMode  | string  | true  | Margin Mode **ISOLATION** **CROSS**  |
| symbol  | string  | true  | Trading pair  |
| marginCoin  | string  | true  | Margin coin  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/account/change_margin_mode' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"marginMode":"ISOLATION","symbol":"BTCUSDT","marginCoin":"USDT"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_margin_mode.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| marginMode  | string  | Margin Mode **ISOLATION** **CROSS**  |
| symbol  | string  | Trading pair  |
| marginCoin  | string  | Margin coin  |
Response Example
json
```
{"code":0,"data":[{"positionMode":"ISOLATION"}],"msg":"Success"}
```