---
content_hash: sha256:fe3762821d0d85e85d26f5dc64e599c31b7fb0ecc6398dc5e7563429f9a1ebd4
crawled_at: '2026-05-28T18:54:24.709074+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html
tags:
- bitunix-api-future
- web-docs
title: Place Position TP/SL Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#VPContent)
Menu
Return to top
# Place Position TP/SL Order [​](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#place-position-tp-sl-order)
Rate Limit: 10 req/sec/UID
### Description [​](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#description)
Place Position TP/SL OrderWhen triggered, it will close the position at market price based on the position quantity at that time.Each position can only have one Position TP/SL Order
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#http-request)
  * POST /api/v1/futures/tpsl/position/place_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair  |
| positionId  | string  | true  | Position ID associated with take-profit and stop-loss  |
| tpPrice  | string  | false  | Take-profit trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| tpStopType  | string  | false  | Take-profit trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
| slPrice  | string  | false  | Stop-loss trigger priceAt least one of `tpPrice` or `slPrice` is required.  |
| slStopType  | string  | false  | Stop-loss trigger typeLAST_PRICEMARK_PRICE Default is market price.  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/tpsl/position/place_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"symbol":"BTCUSDT","positionId":"111","tpPrice":"12","tpStopType":"LAST_PRICE","slPrice":"9","slStopType":"LAST_PRICE"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/tp_sl/place_position_tp_sl_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | TP/SL Order ID  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111"},"msg":"Success"}
```