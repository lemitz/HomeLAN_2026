module homelan-server

go 1.21

require (
	github.com/gorilla/websocket v1.5.3
	github.com/hashicorp/mdns v1.0.6
	github.com/mutecomm/go-sqlcipher/v4 v4.4.2
	golang.org/x/crypto v0.32.0
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/miekg/dns v1.1.55 // indirect
	golang.org/x/mod v0.17.0 // indirect
	golang.org/x/net v0.34.0 // indirect
	golang.org/x/sync v0.10.0 // indirect
	golang.org/x/sys v0.29.0 // indirect
	golang.org/x/tools v0.21.1-0.20240508182429-e35e4ccd0d2d // indirect
)

replace (
	golang.org/x/crypto => github.com/golang/crypto v0.32.0
	golang.org/x/mod => github.com/golang/mod v0.17.0
	golang.org/x/net => github.com/golang/net v0.34.0
	golang.org/x/sync => github.com/golang/sync v0.10.0
	golang.org/x/sys => github.com/golang/sys v0.29.0
	golang.org/x/telemetry => github.com/golang/telemetry v0.0.0-20240228155512-f48c80bd79b2
	golang.org/x/term => github.com/golang/term v0.28.0
	golang.org/x/text => github.com/golang/text v0.21.0
	golang.org/x/tools => github.com/golang/tools v0.21.1-0.20240508182429-e35e4ccd0d2d
	golang.org/x/xerrors => github.com/golang/xerrors v0.0.0-20200804184101-5ec99f83aff1
	gopkg.in/check.v1 => github.com/go-check/check v0.0.0-20161208181325-20d25e280405
	gopkg.in/yaml.v3 => github.com/go-yaml/yaml/v3 v3.0.1
	lukechampine.com/uint128 => github.com/lukechampine/uint128 v1.2.0
)
