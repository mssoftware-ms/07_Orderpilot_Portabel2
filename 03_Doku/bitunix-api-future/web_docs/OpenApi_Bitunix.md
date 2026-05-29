---
content_hash: sha256:959e5fe8112ab49f5758c6325a25d24f0b15e2bc35d83aa088e72ed3759634ba
crawled_at: '2026-05-28T18:54:24.951418+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/futures/websocket/public/MarketPrice%20Channel.html
tags:
- bitunix-api-future
- web-docs
title: OpenApi ｜ Bitunix
tool_used: crawl4ai
---

[ Skip to content ](https://www.bitunix.com/api-docs/futures/websocket/public/MarketPrice%20Channel.html#VPContent)
Menu
Return to top
### Description [​](https://www.bitunix.com/api-docs/futures/websocket/public/MarketPrice%20Channel.html#description)
### Request Parameters [​](https://www.bitunix.com/api-docs/futures/websocket/public/MarketPrice%20Channel.html#request-parameters)
| Parameter  | Type  | Required  | Description  |
| --- | --- | --- | --- |
| op  | String  | Yes  | Operation, subscribe unsubscribe  |
| args  | List<Object>  | Yes  | op list  |
| > symbol  | String  | Yes  | Product ID e.g: ETHUSDT  |
| > ch  | String  | Yes  | Channel, price  |
request example:
json
```

    "op":"subscribe",
    "args":[

            "symbol":"BTCUSDT",
            "ch":"price"



```

### Push Parameters [​](https://www.bitunix.com/api-docs/futures/websocket/public/MarketPrice%20Channel.html#push-parameters)
| Parameter  | Type  | Description  |
| --- | --- | --- |
| ch  | String  | Channel name  |
| symbol  | String  | Product ID E.g. ETHUSDT  |
| ts  | int64  | Time stamp  |
| data  | List<String>  | Subscription data  |
| > mp  | String  | Market price  |
| > ip  | String  | Index price  |
| > fr  | String  | Funding rate  |
| > ft  | String  | Funding rate settlement time  |
| > nft  | String  | Next funding rate settlement time  |
push data:
json
```

  "ch": "price"
  "symbol": "BNBUSDT",
  "ts": 1732178884994,
  "data":{
        "ip": "0.0010"
        "mp": "10000"
        "fr": "0.013461"
        "ft": "2024-12-04T11:00:00Z"
        "nft": "2024-12-04T12:00:00Z"


```