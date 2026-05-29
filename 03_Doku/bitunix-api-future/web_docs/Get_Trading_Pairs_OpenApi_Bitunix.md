---
content_hash: sha256:2f4cd7eaff3b882422fdcfce89e3c94f73264241abca8d94143be6a468092413
crawled_at: '2026-05-28T18:54:24.605529+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html
tags:
- bitunix-api-future
- web-docs
title: Get Trading Pairs | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#VPContent)
Menu
Return to top
# Get Trading Pairs [​](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#get-trading-pairs)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#description)
Interface is used to get future trading pair details.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#http-request)
  * GET /api/v1/futures/market/trading_pairs

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbols  | string  | false  | Trading pairs, based on the symbolName, i.e. BTCUSDT,ETHUSDT,XRPUSDT  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/trading_pairs?symbols=BTCUSDT,ETHUSDT'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_trading_pairs.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| symbol  | string  | Coin pair name i.e. BTCUSDT  |
| base  | string  | Base currency Specifically refers to ETH as in ETHUSDT  |
| quote  | string  | Base currency Specifically refers to USDT as in ETHUSDT  |
| minTradeVolume  | string  | Minimum opening amount (base currency)  |
| minBuyPriceOffset  | string  | Minimum price offset for buy orders  |
| maxSellPriceOffset  | string  | Maximum price offset for sell orders  |
| maxLimitOrderVolume  | string  | Maximum limit order base amount  |
| maxMarketOrderVolume  | string  | Maximum market order base amount  |
| basePrecision  | int  | Max precision of opening amount  |
| quotePrecision  | int  | Max precision of order price  |
| maxLeverage  | int  | Max leverage  |
| minLeverage  | int  | Min leverage  |
| defaultLeverage  | int  | Default Leverage  |
| defaultMarginMode  | string  | Default margin mode **Isolation** **Cross**  |
| priceProtectScope  | string  | Price protection scope. For example: current mark price is:10000 priceProtectScope=0.02, the minimum sell order price = 10000*(1-0.02)=9800; the maximum buy order price = 10000*(1+0.02) = 10200  |
| symbolStatus  | string  |  **OPEN** : trade normal **CANCEL_ONLY** : cancel only **STOP** : can't open/close position  |
Response Example
json
```
{"code":0,"data":[{"symbol":"BTCUSDT","base":"BTC","quote":"USDT","minTradeVolume":"0.0001","minBuyPriceOffset":"-0.95","maxSellPriceOffset":"100","maxLimitOrderVolume":"100000","maxMarketOrderVolume":"50000","basePrecision":4,"quotePrecision":1,"minLeverage":1,"maxLeverage":125,"defaultLeverage":20,"defaultMarginMode":1,"priceProtectScope":"0.02","symbolStatus":"OPEN"}],"msg":"Success"}
```