---
content_hash: sha256:1aed97db631ef1057fb0c9d28fb870fe8c7a77e474fb2b90f03cdb0a44dfcdd7
crawled_at: '2026-05-28T18:54:24.993834+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/user-ws/
tags:
- bitunix-api-future
- web-docs
title: User ws - Open Platform
tool_used: crawl4ai
---

# User ws
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#websocket-api "Permanent link")
###  [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#websocket-introduction "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#public-interface_1 "Permanent link")
### User Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#order-interface_1 "Permanent link")
#### 1. Query account balance[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#1-query-account-balance "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "user.account",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```

**Parameters**
| Name  | Type  | Mandatory  | Description  |
| --- | --- | --- | --- |
| None  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": [//Account Information
    {
      "coin": "BTC",//Coin
      "balance": 10000.00,//Balance
      "balanceLocked": 1000.00//Locked Balance
    }
  ]
}

```

#### 2. Get user information[¶](https://www.bitunix.com/api-docs/spots/en_us/user-ws/#2-get-user-information "Permanent link")
Same semantics as [REST user · Get user information](https://www.bitunix.com/api-docs/spots/en_us/user/): returns the `uid` for the API key; for a sub-account key, returns the linked master account `uid`. Signing rules are in [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/).

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "user.info",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```

**Parameters**
| Name  | Type  | Mandatory  | Description  |
| --- | --- | --- | --- |
| None  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "uid": 681979174
  }
}

```

The `data` object follows the same contract as REST: `uid` is int64 and may be `null`.