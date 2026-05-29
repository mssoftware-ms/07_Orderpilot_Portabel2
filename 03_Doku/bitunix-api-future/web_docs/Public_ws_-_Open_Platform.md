---
content_hash: sha256:c1eb3b665fac9dd642f5025883b58708e319e2113d7c367be3919c145efb9c0c
crawled_at: '2026-05-28T18:54:24.984575+00:00'
language: en
provider: bitunix-api-future
source_type: web_docs
source_url: https://www.bitunix.com/api-docs/spots/en_us/public-ws/
tags:
- bitunix-api-future
- web-docs
title: Public ws - Open Platform
tool_used: crawl4ai
---

# Public ws
##  [Quick Start](https://www.bitunix.com/api-docs/spots/en_us/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#quick-start "Permanent link")
## Restful API[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#restful-api "Permanent link")
###  [Public Interface](https://www.bitunix.com/api-docs/spots/en_us/public/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#public-interface "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#user-interface "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#order-interface "Permanent link")
## WebSocket API[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#websocket-api "Permanent link")
###  [WebSocket Introduction](https://www.bitunix.com/api-docs/spots/en_us/ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#websocket-introduction "Permanent link")
### Public Interface[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#public-interface_1 "Permanent link")
###  [User Interface](https://www.bitunix.com/api-docs/spots/en_us/user-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#user-interface_1 "Permanent link")
###  [Order Interface](https://www.bitunix.com/api-docs/spots/en_us/order-ws/)[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#order-interface_1 "Permanent link")
#### 1. Get latest price[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#1-get-latest-price "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "market.last_price",
  "params": {
    "symbol": "BTC",
    "nonce": "17832",
    "timestamp": 1724285700000,
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Type  | Mandatory  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Pair  |
**Response**

```
{
"id": "2d812f20c9e1030f5551eab0e039f613",
"code": "0",
"msg": "success",
"data": "10000.00" //Latest Price
}

```

#### 2. Get depth data[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#2-get-depth-data "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "market.depth",
  "params": {
    "symbol": "BTC",
    "precision": 5,
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Paremeter**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading pair  |
| precision  | number  | Y  | token precision  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "asks": [//Sell
      {
        "price": "10000.00",//Order Price
        "volume": "10.00"//Order Quantity
      }
    ],
    "bids": [//Buy
      {
        "price": "9990.00",//Order Price
        "volume": "10.00"//Order Quantity
      }
    ],
    "ts": "1724285700000"//Timestamp
  }
}

```

#### 3. Get K-Line Data[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#3-get-k-line-data "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "market.kline",
  "params": {
    "symbol": "BTC",
    "interval": "1min",
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Paremeter**
| Name  | Types  | Mandatory  | Descrtiption  |
| --- | --- | --- | --- |
| symbol  | string  | Y  | Trading Pairs  |
| interval  | string  | Y  | kline interval，default: 1min(1,3,5,15,30,60,120,240,360,720,D,M,W)  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": {
    "symbol": "BTC",//Trading Pair
    "open": "10000.00",//Open Price
    "high": "10010.00",//Highest PRice
    "low": "9990.00",//Lowest Price
    "close": "10000.00",//Close Price
    "ts": "1724285700000"//kline Starting Time ISO8601
  }
}

```

#### 4. Query trading pair data[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#4-query-trading-pair-data "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "common.coin_pair.list",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
  }
}

```

**Parameters**
| Name  | Types  | Mandatory  | Descriptio  |
| --- | --- | --- | --- |
| None  |
**Return**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": [
    {
      "id": "1",//id
      "base": "BTC",//Base Token
      "quote": "USDT",//Pricing Token
      "basePrecision": "8",//Base Token Precision
      "quotePrecision": "2",//Pricing Token Precision
      "minPrice": "0.01",//Minimum trading value
      "minVolume": "0.001",//Minimum trading quantity
      "isOpen": "1",//Open or closed for trading
      "isHot": "1",//Trending or not
      "isRecommend": "1",//Recommended or not
      "isShow": "1",//Display or hidden
      "tradeArea": "USDT",//Trading Zone
      "sort": "1",//Order
      "openTime": "2020-01-01 00:00:00",//Open Time
      "precisions": [//Trading Precision
        "0.01",
        "0.001"
      ]
    }
  ]
}

```

#### 5. Query rate data[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#5-query-rate-data "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "common.rate.list",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```

**Parameter**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| None  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": [//Exchange rate
    {
      "baseSymbol": "USD",//Base currency
      "quoteSymbol": "CNY",//Pricing currency
      "rate": "6.5"//Rate
    }
  ]
}

```

#### 6. Query Token Data[¶](https://www.bitunix.com/api-docs/spots/en_us/public-ws/#6-query-token-data "Permanent link")

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "method": "common.coin.coin_network.list",
  "params": {
    "nonce": "17832",
    "timestamp": "1724285700000",
    "apiKey": "9a25209b66004da404d9ddcb48d1e11f",
    "sign": "--signature here--"
    }
}

```

**Parameter**
| Name  | Types  | Mandatory  | Description  |
| --- | --- | --- | --- |
| None  |
**Response**

```
{
  "id": "2d812f20c9e1030f5551eab0e039f613",
  "code": "0",
  "msg": "success",
  "data": [//Token Data
    {
      "name": "BTC",//Token
      "fullName": "Bitcoin",//Token name
      "logo": "https://www.bitunix.com/logo.png",//Logo
      "track": "BTC",//Tracks
      "quotePrecision": "8",//Base token
      "minPrice": "0.01",//Minimum amount
      "isOpen": "1",//Open or closed for trading
      "isHot": "1",//Trending or not
      "depositOpen": "1",//Deposit is open or not，0: deposit closed，1: deposit open；
      "isShow": "1",//Display or hidden
      "withdrawOpen": "1",//Withdrawal is open or not，0: closed，1: open；
      "withdrawMin": "0.001",//Minimum Withdrawal Quantity
      "withdrawMax": "1000.00",//Maximum Withdrawal Quantity
      "networks": [//Network Information
        {
          "contractPrecision": "8",//Contract Precision
          "contractAddress": "0x1234567890",//Contract Address
          "requireMemo": "0",//Memo required.0:not required,1:optional,2:required
          "chain": "ETH",//Blockchain
          "depositConfirm": "3",//Deposit Confirmations
          "addressRegular": "0x[0-9a-fA-F]{40}",//Address Format Requirement
          "network": "ETH",//Network Name
          "isOpen": "1",//Open or closed；0:closed，1:open
          "depositOpen": "1",//eposit is open or not，0: deposit closed，1: deposit open；
          "isShow": "1",//Display or hidden
          "withdrawOpen": "1",//Withdrawal is open or not
            "withdrawMin": "0.001",//Minimum Withdrawal Quantity
            "withdrawMax": "1000.00",//Maximum Withdrawal Quantity
            "depositMin": "0.001"//Minimum Deposit Quantity
        }
        ]
    }
    ]
}

```