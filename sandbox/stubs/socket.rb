# WASI has no sockets, so Ruby's socket extension is not part of ruby.wasm.
#
# ActiveSupport reaches ipaddr on its way through core_ext/object/json, and
# ipaddr only ever reads these address-family constants -- it never opens
# anything.  Nothing in the sandbox does networking, so a stub is enough.
class Socket
  AF_UNSPEC = 0
  AF_INET   = 2
  AF_INET6  = 10
end
