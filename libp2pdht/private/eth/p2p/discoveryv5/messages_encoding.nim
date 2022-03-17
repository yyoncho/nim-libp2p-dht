# nim-eth - Node Discovery Protocol v5
# Copyright (c) 2020-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
#
## Discovery v5 packet encoding as specified at
## https://github.com/ethereum/devp2p/blob/master/discv5/discv5-wire.md#packet-encoding

import
  std/net,
  stew/arrayops,
  eth/[rlp],
  chronicles,
  libp2p/routing_record,
  libp2p/signed_envelope,
  "."/[messages, spr, node],
  ../../../../dht/providers_encoding

from stew/objects import checkedEnumAssign

type
  DecodeResult*[T] = Result[T, cstring]

proc read*(rlp: var Rlp, T: type RequestId): T
    {.raises: [ValueError, RlpError, Defect].} =
  mixin read
  var reqId: RequestId
  reqId.id = rlp.toBytes()
  if reqId.id.len > 8:
    raise newException(ValueError, "RequestId is > 8 bytes")
  rlp.skipElem()

  reqId

proc append*(writer: var RlpWriter, value: RequestId) =
  writer.append(value.id)

proc read*(rlp: var Rlp, T: type IpAddress): T
    {.raises: [RlpError, Defect].} =
  let ipBytes = rlp.toBytes()
  rlp.skipElem()

  if ipBytes.len == 4:
    var ip: array[4, byte]
    discard copyFrom(ip, ipBytes)
    IpAddress(family: IPv4, address_v4: ip)
  elif ipBytes.len == 16:
    var ip: array[16, byte]
    discard copyFrom(ip, ipBytes)
    IpAddress(family: IPv6, address_v6: ip)
  else:
    raise newException(RlpTypeMismatch,
      "Amount of bytes for IP address is different from 4 or 16")

proc append*(writer: var RlpWriter, ip: IpAddress) =
  case ip.family:
  of IpAddressFamily.IPv4:
    writer.append(ip.address_v4)
  of IpAddressFamily.IPv6: writer.append(ip.address_v6)

proc read*(rlp: var Rlp, T: type NodeId): T
    {.raises: [ValueError, RlpError, Defect].} =
  mixin read
  let nodeId = NodeId.fromBytesBE(rlp.toBytes())
  rlp.skipElem()
  nodeId

proc append*(writer: var RlpWriter, value: NodeId) =
  writer.append(value.toBytesBE)

proc numFields(T: typedesc): int =
  for k, v in fieldPairs(default(T)): inc result

proc encodeMessage*[T: SomeMessage](p: T, reqId: RequestId): seq[byte] =
  # TODO: Remove all RLP encoding in favour of Protobufs
  result = newSeqOfCap[byte](64)
  result.add(messageKind(T).ord)

  const
    usePbs = T is AddProviderMessage | GetProvidersMessage | ProvidersMessage
    sz = if usePbs: 1 else: numFields(T)

  var writer = initRlpList(sz + 1)
  writer.append(reqId)

  when usePbs:
    let encoded =
      try: p.encode()
      except ResultError[CryptoError] as e:
        error "Failed to encode protobuf message", typ = $T, msg = e.msg
        @[]
    writer.append(encoded)
    trace "Encoded protobuf message", typ = $T, encoded
  else:
    for k, v in fieldPairs(p):
      writer.append(v)
  result.add(writer.finish())

proc decodeMessage*(body: openArray[byte]): DecodeResult[Message] =
  # TODO: Remove all RLP decoding in favour of Protobufs
  ## Decodes to the specific `Message` type.
  if body.len < 1:
    return err("No message data")

  var kind: MessageKind
  if not checkedEnumAssign(kind, body[0]):
    return err("Invalid message type")

  var message = Message(kind: kind)
  var rlp = rlpFromBytes(body.toOpenArray(1, body.high))
  if rlp.enterList:
    try:
      message.reqId = rlp.read(RequestId)
    except RlpError, ValueError:
      return err("Invalid request-id")

    proc decode[T](rlp: var Rlp, v: var T)
        {.nimcall, raises:[RlpError, ValueError, Defect].} =
      for k, v in v.fieldPairs:
        v = rlp.read(typeof(v))

    try:
      case kind
      of unused: return err("Invalid message type")
      of ping: rlp.decode(message.ping)
      of pong: rlp.decode(message.pong)
      of findNode: rlp.decode(message.findNode)
      of findNodeFast: rlp.decode(message.findNodeFast)
      of nodes: rlp.decode(message.nodes)
      of talkReq: rlp.decode(message.talkReq)
      of talkResp: rlp.decode(message.talkResp)
      of addProvider:
        let res = AddProviderMessage.decode(rlp.toBytes)
        if res.isOk:
          message.addProvider = res.get
        else:
          return err "Unable to decode AddProviderMessage"
      of getProviders:
        let res = GetProvidersMessage.decode(rlp.toBytes)
        if res.isOk:
          message.getProviders = res.get
        else:
          return err "Unable to decode GetProvidersMessage"
      of providers:
        let res = ProvidersMessage.decode(rlp.toBytes)
        if res.isOk:
          message.provs = res.get
        else:
          return err "Unable to decode ProvidersMessage"
      of regTopic, ticket, regConfirmation, topicQuery:
        # We just pass the empty type of this message without attempting to
        # decode, so that the protocol knows what was received.
        # But we ignore the message as per specification as "the content and
        # semantics of this message are not final".
        discard
    except RlpError, ValueError:
      return err("Invalid message encoding")

    ok(message)
  else:
    err("Invalid message encoding: no rlp list")

