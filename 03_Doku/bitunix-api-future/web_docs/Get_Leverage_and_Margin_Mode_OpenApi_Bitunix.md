---
content_hash: sha256:c83c6bcc4455664161a9a2d9ad73f31931bbe2c8adcb469d824e848a51406bfc
crawled_at: '2026-05-28T18:54:24.639934+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html
tags:
- bitunix-api-future
- web-docs
title: Get Leverage and Margin Mode | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#VPContent)
Menu
Return to top
# Get Leverage and Margin Mode [​](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#get-leverage-and-margin-mode)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#description)
get Leverage and Margin Mode
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#http-request)
  * GET /api/v1/futures/account/get_leverage_margin_mode

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| marginCoin  | string  | true  | Margin coin  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/account/get_leverage_margin_mode?symbol=BTCUSDT&marginCoin=USDT' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/get_leverage_and_margin_mode.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| symbol  | string  | Trading pair  |
| marginCoin  | string  | Margin coin  |
| leverage  | int  | leverage  |
| marginMode  | string  |  **ISOLATION** or **CROSS**  |
Response Example
json
```
{"code":0,"data":{"symbol":"BTCUSDT","marginCoin":"USDT","leverage":10,"marginMode":"ISOLATION"},"msg":"Success"}
```