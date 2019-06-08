write(io::IO, obj) = Base.write(io, write(obj))

defaultminimum(::Union{Nothing, Missing}) = 4
defaultminimum(::Number) = 20
defaultminimum(x::Bool) = x ? 4 : 5
defaultminimum(x) = sizeof(x)

function write(obj::T) where {T}
    len = defaultminimum(obj)
    buf = len < Mmap.PAGESIZE ? zeros(UInt8, len) : Mmap.mmap(Vector{UInt8}, len)
    buf, pos = write(StructType(T), buf, 1, length(buf), obj)
    return SubString(String(buf), 1, pos - 1)
end

_getfield(x, i) = isdefined(x, i) ? Core.getfield(x, i) : nothing
_isempty(x, i) = !isdefined(x, i) || _isempty(getfield(x, i))
_isempty(x::Union{AbstractDict, AbstractArray, AbstractString, Tuple, NamedTuple}) = isempty(x)
_isempty(::Number) = false
_isempty(::Nothing) = true
_isempty(x) = false

@noinline function realloc!(buf, len)
    new = Mmap.mmap(Vector{UInt8}, trunc(Int, len * 1.25))
    copyto!(buf, 1, new, len)
    return new, length(new)
end

macro check(n)
    esc(quote
        if (pos + $n - 1) > len
            buf, len = realloc!(buf, len)
        end
    end)
end

macro writechar(chars...)
    block = quote
        @boundscheck @check($(length(chars)))
    end
    for c in chars
        push!(block.args, quote
            @inbounds buf[pos] = UInt8($c)
            pos += 1
        end)
    end
    #println(macroexpand(@__MODULE__, block))
    return esc(block)
end

# generic object writing
function write(::Union{Struct, Mutable, AbstractType}, buf, pos, len, x::T) where {T}
    @writechar '{'
    N = fieldcount(T)
    N == 0 && @goto done
    excl = excludes(T)
    nms = names(T)
    emp = omitempties(T)
    Base.@nexprs 32 i -> begin
        k_i = fieldname(T, i)
        if !symbolin(excl, k_i) && (!symbolin(emp, k_i) || !_isempty(x, i))
            buf, pos = write(StringType(), buf, pos, len, jsonname(nms, k_i))
            @writechar ':'
            buf, pos = write(StructType(fieldtype(T, i)), buf, pos, len, _getfield(x, i))
            i < N && @writechar ','
        end
        N == i && @goto done
    end
    if N > 32
        for i = 33:N
            k_i = fieldname(T, i)
            if !symbolin(excl, k_i) && (!symbolin(emp, k_i) || !_isempty(x, i))
                buf, pos = write(StringType(), buf, pos, len, jsonname(nms, k_i))
                @writechar ':'
                buf, pos = write(StructType(fieldtype(T, i)), buf, pos, len, _getfield(x, i))
                i < N && @writechar ','
            end
        end
    end

@label done
    @writechar '}'
    return buf, pos
end

function write(::ObjectType, buf, pos, len, x::T) where {T}
    @writechar '{'
    n = length(x)
    i = 1
    for (k, v) in x
        buf, pos = write(StringType(), buf, pos, len, Base.string(k))
        @writechar ':'
        buf, pos = write(StructType(v), buf, pos, len, v)
        if i < n
            @writechar ','
        end
        i += 1
    end

@label done
    @writechar '}'
    return buf, pos
end

function write(::ArrayType, buf, pos, len, x::T) where {T}
    @writechar '['
    n = length(x)
    i = 1
    for y in x
        buf, pos = write(StructType(y), buf, pos, len, y)
        if i < n
            @writechar ','
        end
        i += 1
    end
    @writechar ']'
    return buf, pos
end

function write(::NullType, buf, pos, len, x)
    @writechar 'n' 'u' 'l' 'l'
    return buf, pos
end

function write(::BoolType, buf, pos, len, x)
    if x
        @writechar 't' 'r' 'u' 'e'
    else
        @writechar 'f' 'a' 'l' 's' 'e'
    end
    return buf, pos
end

# adapted from base/intfuncs.jl
function write(::NumberType, buf, pos, len, y)
    x, neg = Base.split_sign(y)
    n = i = neg + ndigits(x, base=10, pad=1)
    @check i
    while i > neg
        @inbounds buf[pos + i - 1] = 48 + rem(x, 10)
        x = oftype(x, div(x, 10))
        i -= 1
    end
    if neg
        @inbounds @writechar UInt8('-')
    end
    return buf, pos + n
end

const NEEDESCAPE = Set(map(UInt8, ('"', '\\', '\b', '\f', '\n', '\r', '\t')))

function escapechar(b)
    b == UInt8('"')  && return UInt8('"')
    b == UInt8('\\') && return UInt8('\\')
    b == UInt8('\b') && return UInt8('b')
    b == UInt8('\f') && return UInt8('f')
    b == UInt8('\n') && return UInt8('n')
    b == UInt8('\r') && return UInt8('r')
    b == UInt8('\t') && return UInt8('t')
    return 0x00
end

iscntrl(c::Char) = c <= '\x1f' || '\x7f' <= c <= '\u9f'
function escaped(b)
    if b == UInt8('/')
        return [UInt8('/')]
    elseif b >= 0x80
        return [b]
    elseif b in NEEDESCAPE
        return [UInt8('\\'), escapechar(b)]
    elseif iscntrl(Char(b))
        return UInt8[UInt8('\\'), UInt8('u'), Base.string(b, base=16, pad=4)...]
    else
        return [b]
    end
end

const ESCAPECHARS = [escaped(b) for b = 0x00:0xff]
const ESCAPELENS = [length(x) for x in ESCAPECHARS]

function escapelength(str)
    bytes = codeunits(str)
    x = 0
    @simd for i = 1:length(bytes)
        @inbounds len = ESCAPELENS[bytes[i] + 0x01]
        x += len
    end
    return x
end

function write(::StringType, buf, pos, len, x)
    sz = sizeof(x)
    el = escapelength(x)
    @check (el + 2)
    @writechar '"'
    bytes = codeunits(x)
    if el > sz
        for i = 1:sz
            @inbounds escbytes = ESCAPECHARS[bytes[i] + 0x01]
            for j = 1:length(escbytes)
                @inbounds buf[pos] = escbytes[j]
                pos += 1
            end
        end
    else
        @simd for i = 1:sz
            @inbounds buf[pos] = bytes[i]
            pos += 1
        end
    end
    @writechar '"'
    return buf, pos
end

function write(::StringType, buf, pos, len, x::Symbol)
    ptr = Base.unsafe_convert(Ptr{UInt8}, x)
    slen = ccall(:strlen, Csize_t, (Cstring,), ptr)
    @check (slen + 2)
    @inbounds @writechar '"'
    for i = 1:slen
        @inbounds @writechar unsafe_load(ptr, i)
    end
    @inbounds @writechar '"'
    return buf, pos
end

function write(::NumberType, buf, pos, len, x::T) where {T <: Base.IEEEFloat}
    if !isfinite(x)
        @writechar 'n' 'u' 'l' 'l'
        return buf, pos
    end
    bytes = codeunits(string(x))
    sz = sizeof(bytes)
    @check sz
    for i = 1:sz
        @inbounds @writechar bytes[i]
    end

    return buf, pos
end