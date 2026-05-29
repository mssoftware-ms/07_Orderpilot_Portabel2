---
content_hash: sha256:9b88b1eaaa9d05f71fe812eaa3db5061a8f01472cbc3df451b91784f396cb05c
crawled_at: '2026-05-28T18:54:24.717941+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Cancel TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#VPContent)
Menu
Return to top
# Cancel TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#cancel-tp-sl-order)
Rate Limit: 10 req/sec/UID
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#description)
Cancel TP/SL OrderSuccessful interface response is not necessarily equal to the success of the operation, please use the websocket push message as an accurate judgment of the success of the operation.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#http-request)
  * POST /api/v1/futures/tpsl/cancel_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | coin Pair  |
| orderId  | string  | true  | TP/SL Order ID  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/cancel_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","orderId":"12"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/cancel_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | TP/SL Order ID  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111"},"msg":"Success"}
```