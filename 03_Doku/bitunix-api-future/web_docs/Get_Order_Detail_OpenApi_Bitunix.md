---
content_hash: sha256:17bc326ba3b4fea42393246b8638c4f7d98174e37a2996733a06def5bb2e874e
crawled_at: '2026-05-28T18:54:24.797356+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html
tags:
- bitunix-api-future
- web-docs
title: Get Order Detail | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#VPContent)
Menu
Return to top
# Get Order Detail [​](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#get-order-detail)
Rate Limit: 10 req/sec/uid
### Description [​](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#description)
get Order Detail
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#http-request)
  * GET /api/v1/futures/trade/get_order_detail

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| orderId  | string  | false  | order idAt least one of `orderId` or `clientId` is required.  |
| clientId  | string  | false  | client idAt least one of `orderId` or `clientId` is required.  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/trade/get_order_detail?orderId=12345' \
   -H "api-key:*******" \
   -H "sign:*" \
   -H "nonce:your-nonce" \
   -H "timestamp:1659076670000" \
   -H "language:en-US" \
   -H "Content-Type: application/json"
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/trade/get_order_detail.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| orderId  | string  | order id  |
| symbol  | string  | Trading pair  |
| qty  | string  | Amount (base coin)  |
| tradeQty  | string  | Fill amount (base coin)  |
| positionMode  | string  | ONE_WAY or HEDGE  |
| marginMode  | string  | ISOLATION or CROSS  |
| leverage  | int  | leverage  |
| price  | string  | Price of the order.Required if the order type is **LIMIT**  |
| side  | string  | Order directionbuy: **BUY** sell: **SELL**  |
| orderType  | string  | Order type**LIMIT** : limit orders**MARKET** : market orders  |
| effect  | string  | Order expiration date.Required if the orderType is limit**IOC** : Immediate or cancel**FOK** : Fill or kill**GTC** : Good till canceled(default value)**POST_ONLY** : POST only  |
| clientId  | string  | Customize order ID  |
| reduceOnly  | boolean  | Whether or not to just reduce the position  |
| status  | string  |  **INIT** :prepare status**NEW** :pending**PART_FILLED** :partially filled**CANCELED** :canceled**FILLED** All filled  |
| fee  | string  | fee  |
| realizedPNL  | string  | realized pnl  |
| tpPrice  | string  | take profit trigger price  |
| tpStopType  | string  | take profit trigger type **MARK_PRICE** **LAST_PRICE**  |
| tpOrderType  | string  | take profit trigger place order type **LIMIT** **MARKET**  |
| tpOrderPrice  | string  | take profit trigger place order price **LIMIT** **MARKET** required if tpOrderType is **LIMIT**  |
| slPrice  | string  | stop loss trigger price  |
| slStopType  | string  | stop loss trigger type **MARK_PRICE** **LAST_PRICE**  |
| slOrderType  | string  | stop loss trigger place order type **LIMIT** **MARKET**  |
| slOrderPrice  | string  | stop loss trigger place order price **LIMIT** **MARKET** required if slOrderType is **LIMIT**  |
| ctime  | int64  | create timestamp  |
| mtime  | int64  | latest modify timestamp  |
Response Example
json
```
{"code":0,"data":{"orderId":"11111","qty":"1","tradeQty":"0.5","price":"60000","symbol":"BTCUSDT","positionMode":"HEDGE","marginMode":"ISOLATION","leverage":15,"status":"PART_FILLED","fee":"0.01","realizedPNL":"1.78","type":"LIMIT","effect":"GTC","reduceOnly":false,"clientId":"22222","tpPrice":"61000","tpStopType":"MARK","tpOrderType":"LIMIT","tpOrderPrice":"61000.1","slPrice":"59000","slStopType":"MARK","slOrderType":"LIMIT","slOrderPrice":"59000.1","source":"api","ctime":1597026383085,"mtime":1597026383085},"msg":"Success"}
```