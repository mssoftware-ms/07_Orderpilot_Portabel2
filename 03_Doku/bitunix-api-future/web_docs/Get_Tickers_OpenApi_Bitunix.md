---
content_hash: sha256:e518ee8a40ba256ae137243795f8184bbd91140048936b3e567b92d87029924c
crawled_at: '2026-05-28T18:54:24.614053+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_tickers.html
tags:
- bitunix-api-future
- web-docs
title: Get Tickers | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#VPContent)
Menu
Return to top
# Get Tickers [​](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#get-tickers)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#description)
Interface is used to get future trading pair tickers.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#http-request)
  * GET /api/v1/futures/market/tickers

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbols  | string  | false  | Trading pairs, based on the symbolName, i.e. BTCUSDT,ETHUSDT,XRPUSDT  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/tickers?symbols=BTCUSDT,ETHUSDT'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_tickers.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| symbol  | string  | Coin pair name i.e. BTCUSDT  |
| markPrice  | string  | mark price  |
| lastPrice  | string  | last price  |
| open  | string  | Entry price of the last 24 hours  |
| last  | string  | last price  |
| quoteVol  | string  | Trading volume of the coin(last 24 hours)  |
| baseVol  | string  | Trading volume of the last 24 hours  |
| high  | string  | 24h high  |
| low  | string  | 24h low  |
Response Example
json
```
{"code":0,"data":[{"symbol":"BTCUSDT","markPrice":"57892.1","lastPrice":"57891.2","open":"6.31","last":"6.31","quoteVol":"0","baseVol":"0","high":"6.31","low":"6.31"},{"symbol":"ETHUSDT","markPrice":"2000","lastPrice":"2020.1","open":"6.31","last":"6.31","quoteVol":"0","baseVol":"0","high":"6.31","low":"6.31"}],"msg":"Success"}
```