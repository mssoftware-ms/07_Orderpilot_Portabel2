---
content_hash: sha256:7eebb9c2ffb4e389741cdc95ff71785926f5f1c04e7e9634c7e64775922c9dab
crawled_at: '2026-05-28T18:54:24.530497+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/market/get_kline.html
tags:
- bitunix-api-future
- web-docs
title: Get Kline | OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/market/get_kline.html#VPContent)
Menu
Return to top
# Get Kline [​](https://www.bitunix.com/api-docs/futures/market/get_kline.html#get-kline)
Rate Limit: 10 req/sec/ip
### Description [​](https://www.bitunix.com/api-docs/futures/market/get_kline.html#description)
Interface is used to get future kline history.
### HTTP Request [​](https://www.bitunix.com/api-docs/futures/market/get_kline.html#http-request)
  * GET /api/v1/futures/market/kline

### Request Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_kline.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | true  | Trading pair, based on the symbolName, i.e. BTCUSDT  |
| startTime  | int64  | false  | The start time is to query the k-lines after this time,The millisecond format of the Unix timestamp, such as 1672410780000  |
| endTime  | int64  | false  | The end time is to query the k-lines before this time,The millisecond format of the Unix timestamp, such as 1672410780000  |
| interval  | string  | true  | kline interval such as 1m 5m 15m 30m 1h 2h 4h 6h 8h 12h 1d 3d 1w 1M  |
| limit  | int  | false  | Default: 100, maximum: 200  |
| type  | string  | false  | Kline type, values: LAST_PRICE, MARK_PRICE; default: LAST_PRICE  |
Request Example
bash
```
curl -X 'GET'  --location 'https://fapi.bitunix.com/api/v1/futures/market/kline?symbol=BTCUSDT&startTime=1&endTime=10234&interval=15m'
```

### Response Parameters [​](https://www.bitunix.com/api-docs/futures/market/get_kline.html#response-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| open  | decimal  | open price  |
| high  | decimal  | high price  |
| low  | decimal  | low price  |
| close  | decimal  | close price  |
| quoteVol  | decimal  | trading amount  |
| quoteVol  | string  | Trading volume of the coin(last 24 hours)  |
| baseVol  | string  | Trading volume of the last 24 hours  |
Response Example
json
```
{"code":0,"data":[{"open":60000,"high":60001,"close":60000,"low":59989.2,"time":111111,"quoteVol":"1","baseVol":"60000","type":"LAST_PRICE"}],"msg":"Success"}
```