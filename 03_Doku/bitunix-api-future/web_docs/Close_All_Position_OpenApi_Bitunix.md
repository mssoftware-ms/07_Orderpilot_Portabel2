---
content_hash: sha256:3df992a4809e80f0b1cfd398c754ce381d54b96108b797fd4a67b56c2e7474e7
crawled_at: '2026-05-28T18:54:24.691813+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/close_all_position.html
tags:
- bitunix-api-future
- web-docs
title: Close All Position | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#VPContent)
Menu
Return to top
# Close All Position [​](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#close-all-position)
Rate Limit: 1 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#description)
Close all positions
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#http-request)
  * POST /api/v1/futures/trade/close_all_position

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | false  | Trading pair  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/close_all_position' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/close_all_position.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
Response Example
json
```
{"code":0,"data":"","msg":"Success"}
```