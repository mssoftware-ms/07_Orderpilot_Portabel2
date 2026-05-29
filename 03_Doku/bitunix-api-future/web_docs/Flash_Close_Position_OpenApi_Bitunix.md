---
content_hash: sha256:7e9c4dc35e3e0f3f428a82c899502b2b8506aaa3bb03e10a7ba16c0f5638dd08
crawled_at: '2026-05-28T18:54:24.832513+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html
tags:
- bitunix-api-future
- web-docs
title: Flash Close Position | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#VPContent)
Menu
Return to top
# Flash Close Position [​](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#flash-close-position)
Rate Limit: 5 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#description)
Close position by position id
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#http-request)
  * POST /api/v1/futures/trade/flash_close_position

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| positionId  | String  | true  | position id  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/flash_close_position' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"positionId":"19848247723672"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/flash_close_position.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| positionId  | string  | Position ID  |
Response Example
json
```
{"code":0,"data":{"positionId":"19848247723672"},"msg":"Success"}
```