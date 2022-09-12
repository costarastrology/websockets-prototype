# websockets-prototype

[![websockets-prototype Build Status](https://github.com/costarastrology/websockets-prototype/actions/workflows/main.yml/badge.svg)](https://github.com/costarastrology/websockets-prototype/actions/workflows/main.yml)


A simple experiment / prototype exploring how to scale webscokets across
multiple servers, using Redis for inter-server communication.


## Build

You can build the project with [stack][stack]:

```sh
stack build
```

For development, you can enable fast builds with file-watching,
documentation-building, & test-running:

```sh
stack test --haddock --fast --file-watch --pedantic
```

To build & open the documentation, run:

```sh
stack haddock --open websockets-prototype
```

[stack]: https://docs.haskellstack.org/en/stable/README/


## Usage

### Interserver Communication

```sh
# Start a server on port 9000
$ PORT=9000 stack run
# Start another server on port 9001
$ PORT=9001 stack run
# Check out the subscriber counts for Redis channels
$ redis-cli
127.0.0.1:6379> PUBSUB NUMSUB ping1 ping2
1) "ping1"
2) (integer) 2
3) "ping2"
4) (integer) 2
127.0.0.1:6379> exit
# Hit the servers, observe both servers printing even though the request was
# only to one.
curl localhost:9000/ping1
curl localhost:9000/ping2
curl localhost:9001/ping1
curl localhost:9001/ping2
```

### Websockets

You'll need a WebSockets client. [Postman][postman] has one built in & is what
we use.

```sh
# Start a server on port 9000
$ PORT=9000 stack run
# Start another server on port 9001
$ PORT=9001 stack run
```

Open a websocket connection to each server in 2 clients via the `/websockets`
route(`ws://localhost:9000/websockets` & `ws://localhost:9001/websockets`). You
should see each server print out the new connection & the list of connected
clients.

In a client, send this message:

```json
{
    "channel": "chat",
    "message": {
        "type": "SubmitMessage",
        "contents": "Hello World"
    }
}
```

The receiving server should print out the parsed message & all clients should
receive this reply back, no matter what server they are connected to:

```json
{
    "channel": "chat",
    "message": {
        "contents": {
            "content": "Hello World",
            "postedAt": "2022-09-09T18:12:45.90481586Z"
        },
        "type": "NewMessageReceived"
    }
}
```

Hit either of the ping API routes with curl:

```sh
curl http://localhost:9001/ping2
```

You should see every websockets client receive this message:

```json
{
    "channel": "ping",
    "message": {
        "contents": 2,
        "type": "Ping"
    }
}
```

[postman]: https://learning.postman.com/docs/sending-requests/websocket/websocket/


## LICENSE

BSD-3
