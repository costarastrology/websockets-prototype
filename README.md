# websockets-prototype

[![websockets-prototype Build Status](https://github.com/costarastrology/websockets-prototype/actions/workflows/main.yml/badge.svg)](https://github.com/costarastrology/websockets-prototype/actions/workflows/main.yml)


A simple experiment / prototype exploring how to scale webscokets across
multiple servers, using Redis for inter-server communication.

Requires [`stack`][get-stack]:

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

[get-stack]: https://docs.haskellstack.org/en/stable/README/


## Install

You can install the CLI exe by running `stack install`. This lets you call the
executable directly instead of through stack:

```sh
stack install
export PATH="${HOME}/.local/bin/:${PATH}"
websockets-prototype
```


## Build

You can build the project with stack:

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


## LICENSE

BSD-3
