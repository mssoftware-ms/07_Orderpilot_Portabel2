---
content_hash: sha256:1f7003496c082271529651e922517cba9ced7339cf992cb72c6471834a5f607b
crawled_at: '2026-05-28T18:54:24.571419+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/account/change_position_mode.html
tags:
- bitunix-api-future
- web-docs
title: Change Position Mode | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#VPContent)
Menu
Return to top
# Change Position Mode [​](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#change-position-mode)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#description)
Adjust the position mode between 'one way mode' and 'hedge mode'
If you want to change the user's position mode on all symbol contracts, you need to specify hedge mode positions or one-way positions. Note: The position mode can't be adjusted when there is an open position order under the product type. Changes the user's position mode for all symbol futures: hedging mode or one-way mode.When users hold positions or orders on any side of any trading pair in the specific product type, the request may fail.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#http-request)
  * POST /api/v1/futures/account/change_position_mode

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| positionMode  | string  | true  | Position Mode **ONE_WAY** **HEDGE**  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/account/change_position_mode' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"positionMode":"HEDGE"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/account/change_position_mode.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| positionMode  | string  | Position Mode **ONE_WAY** **HEDGE**  |
Response Example
json
```
{"code":0,"data":[{"positionMode":"HEDGE"}],"msg":"Success"}
```