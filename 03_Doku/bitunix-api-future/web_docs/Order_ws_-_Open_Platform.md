---
content_hash: sha256:05b019da1b3074caf5285fc9fc7ce5afaddba6d1fc8e4d9057f3b1dc0f417e61
crawled_at: '2026-05-28T18:54:25.047857+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/order-ws/
tags:
- bitunix-api-future
- web-docs
title: Order ws - Open Platform
tool_used: crawl4ai
---

# Order ws
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#websocket-api "Permanent link")
###  [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#websocket-introduction "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#user-interface_1 "Permanent link")
### Order Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#order-interface_1 "Permanent link")
#### 1. Place Order[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#1-place-order "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.place_order",
  "params": {
    "side": 1,
    "type": 1,
    "volume": "100",
    "price": "10000",
    "symbol": "BTCUSDT",
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| side  | number  | Y  | Side(1: Sell 2: Buy)  |
| type  | number  | Y  | Order type(1:Limit 2:Market)  |
| volume  | string  | Y  | when put limit order, **volume** means base coin's quantity, when put market order, **volume** means quote coin's quantity  |
| price  | string  | Y  | Order Price  |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "orderId": "123456",//OrderID
    "side": 1,//Side(1: Sell 2: Buy)
    "type": 1,//Order type(1:Limit 2:Market)
    "volume": "100",//Amount
    "price": "10000",//Order Price
    "symbol": "BTCUSDT",//Trading Pair
    "placeStatus": "1"//Whether order is placed successfully, 1: Success
  }
}

```

#### 2. Batch Order[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#2-batch-order "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.place_order.batch",
  "params": {
    "orderList": [
      {
        "side": 1,
        "type": 1,
        "volume": "100",
        "price": "10000",
        "symbol": "BTCUSDT"
      },
      {
        "side": 2,
        "type": 1,
        "volume": "100",
        "price": "10000",
        "symbol": "BTCUSDT"
      }
    ],
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| orderList  | object[]  | Y  | All orders  |
orderList
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| side  | number  | Y  | Side(1: Sell 2: Buy)  |
| type  | number  | Y  | Order type(1:Limit 2:Market)  |
| volume  | string  | Y  | when put limit order, **volume** means base coin's quantity, when put market order, **volume** means quote coin's quantity  |
| price  | string  | Y  | Order Price  |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": [
    {
      "orderId": "123456",//OrderID
      "side": 1,//Side(1: Sell 2: Buy)
      "type": 1,//Order type(1:Limit 2:Market)
      "volume": "100",//Amount
      "price": "10000",//Order Price
      "symbol": "BTCUSDT",//Trading Pair
      "placeStatus": "1"//Whether order is placed successfully, 1: Success
    }
  ]
}

```

#### 3. Cancel order / Batch cancel[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#3-cancel-order-batch-cancel "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.cancel",
  "params": {
    "orderIdList": [
      {
        "orderId": "123456",
        "symbol": "BTCUSDT"
        }
    ],
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| orderIdList  | object[]  | Y  | All canceled orders  |
orderIdList
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": null
}

```

#### 4. Query matching order[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#4-query-matching-order "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.deal.list",
  "params": {
    "orderId": "123456",
    "symbol": "BTCUSDT",
    "nonce": "17832",
        "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| orderId  | string  | Y  | Order ID  |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "volume": "100",//Filled Amount
    "price": "10000",//Filled Price
    "fee": "0.1",//Fee
    "feeCoin": "BTC",//Fee Token
    "role": "1",//Type(1-Maker 2-Taker)
    "ctime": "2019-01-01T00:00:00Z",//Filled Time(ISO8601)
    "id": "123456"//Matching Order ID
  }
}

```

#### 5. Query order history[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#5-query-order-history "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.history.page",
  "params": {
    "page": 1,
    "pageSize": 10,
    "startTime": "2019-01-01T00:00:00Z",
    "endTime": "2019-01-01T00:00:00Z",
    "status": "2",
    "side": "1",
    "type": "1",
    "symbol": "BTCUSDT",
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| page  | number  | N  | Page  |
| pageSize  | number  | N  | Items per page  |
| startTime  | string  | N  | Order creation start time(ISO8601)  |
| endTime  | string  | N  | Order creation end time(ISO8601)  |
| status  | string  | N  | Status(1: Unfilled, 2: Filled, 3: Partially Filled, 4: Canceled, 7: Partially Filled anc canceled)  |
| side  | string  | N  | Side(1: Sell 2: Buy)  |
| type  | string  | N  | Order Type(1Limit2Market)  |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "total": 100,
    "pageNum": 1,
    "pageSize": 10,
    "data": [
      {
        "orderId": "123456",//Order ID
        "userId": "123456",//User UID
        "orderType": "1",//Order Type，1.Limit，2.Market
        "amount": "100",//Order Value(Base Token)
        "dealAmount": "100",//Filled Amount
        "volume": "100",//Filled Value(Pricing Token)
        "leftAmount": "100",//Remaining Value(Pricing Token)
        "volume": "100",//Order Amount(Base token)
        "dealVolume": "100",//Filled Amount (Base token)
        "leftVolume": "100",//Remaining Amount (Base token)
        "status": "2",//Status（1: Unfilled, 2: Filled, 3: Partially Filled, 4: Canceled, 7: Partially Filled anc canceled）
        "type": "1",//1.Limit，2.Market
        "side": "1",//Side(1: Sell 2: Buy)
        "price": "10000",//Order Price
        "avgPrice": "10000",//Average Filled Price
        "progress": "100",//Filled Percentage Unit: 1%, 15.8 means 15.8%
        "ctime": "2019-01-01T00:00:00Z",//Order Creatio Time
        "utime": "2019-01-01T00:00:00Z",//Order Edit Time
        "base": "BTC",//Base token
        "quote": "USDT",//Pricing Token
        "symbol": "BTCUSDT",//Trading Pair
        "fee": "0.1",//Fee
        "feeCoin": "BTC"//Fee Token
        }
    ]
    }
}

```

#### 6. Query current orders[¶](https://www.bitunix.com/api-docs/spots/en_us/order-ws/#6-query-current-orders "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "order.pending.list",
  "params": {
    "symbol": "BTCUSDT",
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading Pair  |
**Response**

```
{
"id": "2d812f20c9e1030f5551eab0e039f613",
"code": "0",
"msg": "success",
"data": [
    {
    "orderId": "123456",//Order ID
    "userId": "123456",//UID
    "orderType": "1",//Order Type，1.Limit，2.Market
    "amount": "100",//Order Value(Base Token)
    "dealAmount": "100",//Filled Amount
    "volume": "100",//Filled Value(Pricing Token)
    "leftAmount": "100",//Remaining Value(Pricing Token)
    "volume": "100",//Order Amount(Base token)
    "dealVolume": "100",//Filled Amount (Base token)
    "leftVolume": "100",//Remaining Amount (Base token)
    "status": "2",//Status（1: Unfilled, 2: Filled, 3: Partially Filled, 4: Canceled, 7: Partially Filled anc canceled）
    "type": "1",//1.Limit，2.Market
    "side": "1",//Side(1: Sell 2: Buy)
    "price": "10000",//Order Price
    "avgPrice": "10000",//Average Filled Price
    "progress": "100",//Filled Percentage Unit: 1%, 15.8 means 15.8%
    "ctime": "2019-01-01T00:00:00Z",//Order Creation Time
    "utime": "2019-01-01T00:00:00Z",//Order Edit Time
    "base": "BTC",//Base token
    "quote": "USDT",//Pricing Token
    "symbol": "BTCUSDT",//Trading Pair
    "fee": "0.1",//Fee
    "feeCoin": "BTC"//Fee Token
    }
]
}

```