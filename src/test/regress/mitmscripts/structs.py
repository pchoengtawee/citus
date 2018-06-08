from construct import (
    Struct,
    Int8ub, Int16ub, Int32ub, Int16sb, Int32sb,
    Bytes, CString, Computed, Switch, Seek, this, Pointer,
    GreedyRange, Enum, Byte, Probe, FixedSized, RestreamData, GreedyBytes, Array
)
import construct.lib as cl

class MessageMeta(type):
    def __init__(cls, name, bases, namespace):
        if not hasattr(cls, "_msgtypes"):
            raise Exception("classes which use MessageMeta must have a '_msgtypes' field")

        if not hasattr(cls, "_classes"):
            raise Exception("classes which use MessageMeta must have a '_classes' field")

        if not hasattr(cls, "struct"):
            # This is one of the direct subclasses
            return

        if cls.__name__ in cls._classes:
            raise Exception("You've already made a class called {}".format( cls.__name__))
        cls._classes[cls.__name__] = cls

        # add a _type field to the struct so we can identify it while printing structs
        cls.struct = cls.struct + ("_type" / Computed(name))

        if not hasattr(cls, "key"):
            return

        # register the type, so we can tell the parser about it
        key = cls.key
        if key in cls._msgtypes:
            raise Exception('key {} is already assigned to {}'.format(
                key, cls._msgtypes[key].__name__)
            )
        cls._msgtypes[key] = cls

class Message:
    'Do not subclass this object directly. Instead, subclass of one of the below types'

    def print(message):
        'Define this on subclasses you want to change the representation of'
        raise NotImplementedError

    @classmethod
    def _default_print(cls, name, msg):
        recur = cls.print_message
        return "{}({})".format(name, ",".join(
            "{}={}".format(key, recur(value)) for key, value in msg.items()
            if not key.startswith('_')
        ))

    @classmethod
    def print_message(cls, msg):
        if not hasattr(cls, "_msgtypes"):
            raise Exception('Do not call this method on Message, call it on a subclass')

        if isinstance(msg, cl.ListContainer):
            return repr([cls.print_message(message) for message in msg])

        if not isinstance(msg, cl.Container):
            return msg

        if not hasattr(msg, "_type"):
            return cls._default_print("Anonymous", msg)

        if msg._type and msg._type not in cls._classes:
            return cls._default_print(msg._type, msg)

        try:
            return cls._classes[msg._type].print(msg)
        except NotImplementedError:
            return cls._default_print(msg._type, msg)

    @classmethod
    def name_to_struct(cls):
        return {
            _class.__name__: _class.struct
            for _class in cls._msgtypes.values()
        }

    @classmethod
    def name_to_key(cls):
        return {
            _class.__name__ : ord(key)
            for key, _class in cls._msgtypes.items()
        }

class SharedMessage(Message, metaclass=MessageMeta):
    'A message which could be sent by either the frontend or the backend'
    _msgtypes = dict()
    _classes = dict()

class FrontendMessage(Message, metaclass=MessageMeta):
    'A message which will only be sent be a backend'
    _msgtypes = dict()
    _classes = dict()

class BackendMessage(Message, metaclass=MessageMeta):
    'A message which will only be sent be a frontend'
    _msgtypes = dict()
    _classes = dict()

class Query(FrontendMessage):
    key = 'Q'
    struct = Struct(
        "query" / CString("ascii")
    )

    @staticmethod
    def print(message):
        return "Query(query={}".format(message.query)

class Terminate(FrontendMessage):
    key = 'X'
    struct = Struct()

class CopyData(SharedMessage):
    key = 'd'
    struct = Struct(
        'data' / GreedyBytes  # reads all of the data left in this substream
    )

class CopyDone(SharedMessage):
    key = 'c'
    struct = Struct()

class EmptyQueryResponse(BackendMessage):
    key = 'I'
    struct = Struct()

class ReadyForQuery(BackendMessage):
    key='Z'
    struct = Struct("state"/Enum(Byte,
        idle=ord('I'),
        in_transaction_block=ord('T'),
        in_failed_transaction_block=ord('E')
    ))

class CommandComplete(BackendMessage):
    key = 'C'
    struct = Struct(
        "command" / CString("ascii")
    )

class RowDescription(BackendMessage):
    key = 'T'
    struct = Struct(
        "fieldcount" / Int16ub,
        "fields" / Array(this.fieldcount, Struct(
            "_type" / Computed("F"),
            "name" / CString("ascii"),
            "tableoid" / Int32ub,
            "colattrnum" / Int16ub,
            "typoid" / Int32ub,
            "typlen" / Int16sb,
            "typmod" / Int32sb,
            "format_code" / Int16ub,
        ))
    )

class DataRow(BackendMessage):
    key = 'D'
    struct = Struct(
        "_type" / Computed("data_row"),
        "columncount" / Int16ub,
        "columns" / Array(this.columncount, Struct(
            "_type" / Computed("C"),
            "length" / Int16sb,
            "value" / Bytes(this.length)
        ))
    )

class AuthenticationOk(BackendMessage):
    key = 'R'
    struct = Struct()

class ParameterStatus(BackendMessage):
    key = 'S'
    struct = Struct(
        "name" / CString("ASCII"),
        "value" / CString("ASCII"),
    )

    def print(message):
        return "ParameterStatus({}={})".format(message.name, message.value)

class BackendKeyData(BackendMessage):
    key = 'K'
    struct = Struct(
        "pid" / Int32ub,
        "key" / Bytes(4)
    )

    def print(message):
        # Both of these should be censored, for reproducible regression test output
        return "BackendKeyData(XXX)"

frontend_switch = Switch(
    this.type,
    { **FrontendMessage.name_to_struct(), **SharedMessage.name_to_struct() },
    default=Bytes(this.length - 4)
)

backend_switch = Switch(
    this.type,
    {**BackendMessage.name_to_struct(), **SharedMessage.name_to_struct()},
    default=Bytes(this.length - 4)
)

frontend_msgtypes = Enum(Byte, **{
    **FrontendMessage.name_to_key(),
    **SharedMessage.name_to_key()
})

backend_msgtypes = Enum(Byte, **{
    **BackendMessage.name_to_key(),
    **SharedMessage.name_to_key()
})

# It might seem a little circuitous to say a frontend message is a kind of frontend
# message but this lets us easily customize how they're printed

class Frontend(FrontendMessage):
    struct = Struct(
        "type" / frontend_msgtypes,
        "length" / Int32ub,  # "32-bit unsigned big-endian"
        "raw_body" / Bytes(this.length - 4),
        # try to parse the body into something more structured than raw bytes
        "body" / RestreamData(this.raw_body, frontend_switch),  
    )

    def print(message):
        if isinstance(message.body, bytes):
            raise NotImplementedError
        return FrontendMessage.print_message(message.body)

class Backend(BackendMessage):
    struct = Struct(
        "type" / backend_msgtypes,
        "length" / Int32ub,  # "32-bit unsigned big-endian"
        "raw_body" / Bytes(this.length - 4),
        # try to parse the body into something more structured than raw bytes
        "body" / RestreamData(this.raw_body, backend_switch),  
    )

    def print(message):
        if isinstance(message.body, bytes):
            raise NotImplementedError
        return BackendMessage.print_message(message.body)

# GreedyRange keeps reading messages until we hit EOF
frontend_messages = GreedyRange(Frontend.struct)
backend_messages = GreedyRange(Backend.struct)

def parse(message, from_frontend=True):
    if from_frontend:
        message = frontend_messages.parse(message)
    else:
        message = backend_messages.parse(message)
    message.from_frontend = from_frontend

    return message

def print(message):
    if message.from_frontend:
        return FrontendMessage.print_message(message)
    return BackendMessage.print_message(message)
