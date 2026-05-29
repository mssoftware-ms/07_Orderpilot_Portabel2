---
content_hash: sha256:83b1ef121530ca9ff693b3a9f8322f90867c228a7925ff02bc2227fa083587ec
crawled_at: '2026-05-28T18:54:24.754146+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/modify_order.html
tags:
- bitunix-api-future
- web-docs
title: Modify Order | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#VPContent)
Menu
Return to top
# Modify Order [​](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#modify-order)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#description)
Interface for order modification, used to modify an pending order, such as its TP/SL and/or price/qty.Attention!!Successful interface response is not necessarily equal to the success of the operation, please use the websocket push message as an accurate judgment of the success of the operation.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#http-request)
  * POST /api/v1/futures/trade/modify_order

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| orderId  | string  | false  | Order IDEither orderId or clientId is required. If both are entered, orderId prevails.  |
| clientId  | string  | false  | Customize order IDEither orderId or clientId is required. If both are entered, orderId prevails.  |
| qty  | string  | true  | Amount (base coin)  |
| price  | string  | true  | Price of the order.Required if the order type is **LIMIT**  |
| tpPrice  | string  | false  | take profit trigger price  |
| tpStopType  | string  | false  | take profit trigger type **MARK_PRICE** **LAST_PRICE**  |
| tpOrderType  | string  | false  | take profit trigger place order type **LIMIT** **MARKET**  |
| tpOrderPrice  | string  | false  | take profit trigger place order price **LIMIT** **MARKET** required if tpOrderType is **LIMIT**  |
| slPrice  | string  | false  | stop loss trigger price  |
| slStopType  | string  | false  | stop loss trigger type **MARK_PRICE** **LAST_PRICE**  |
| slOrderType  | string  | false  | stop loss trigger place order type **LIMIT** **MARKET**  |
| slOrderPrice  | string  | false  | stop loss trigger place order price **LIMIT** **MARKET** required if slOrderType is **LIMIT**  |
Request Example
bash
```
curl -X 'POST'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/modify_order' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json" \
 --data '{"orderId":"1111","symbol":"BTCUSDT","price":"60000","qty":"0.5","tpPrice":"61000","tpStopType":"MARK","tpOrderType":"LIMIT","tpOrderPrice":"61000.1"}'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/modify_order.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | order id  |
| clientId  | string  | client id  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111","clientId":"22222"},"msg":"Success"}
```