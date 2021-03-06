module FastaIO

using Compat
using GZip

export
    FastaReader,
    readentry,
    rewind,
    readfasta,
    FastaWriter,
    writeentry,
    writefasta

import Base.start, Base.done, Base.next, Base.readall,
       Base.close, Base.show, Base.eof, Base.write

const fasta_buffer_size = 4096

type FastaReader{T}
    # public but read-only
    num_parsed::Int        # number of parsed entries so far
    # private
    f::IO
    is_eof::Bool           # did we reach end of file?
    rbuffer::Vector{UInt8} # read buffer
    rbuf_sz::Int           # read buffer size
    rbuf_pos::Int          # read buffer cursor
    lbuffer::Vector{UInt8} # line buffer
    lbuf_sz::Int           # line buffer size
    mbuffer::Vector{UInt8} # multi-line buffer
    mbuf_sz::Int           # multi-line buffer size
    own_f::Bool
    function FastaReader(filename::AbstractString)
        fr = new(0, gzopen(filename), false,
            Array(UInt8, fasta_buffer_size), 0, 0,
            Array(UInt8, fasta_buffer_size), 0,
            Array(UInt8, fasta_buffer_size), 0,
            true)
        finalizer(fr, close)
        return fr
    end
    function FastaReader(io::IO)
        new(0, io, false,
            Array(UInt8, fasta_buffer_size), 0, 0,
            Array(UInt8, fasta_buffer_size), 0,
            Array(UInt8, fasta_buffer_size), 0,
            false)
    end
end

# typealiases added only to avoid warnings
if VERSION < v"0.5-"
    typealias String UTF8String
    const ST = ASCIIString
else
    typealias UTF8String String
    typealias ASCIIString String
    const ST = String
end

FastaReader(filename::AbstractString) = FastaReader{ST}(filename)
FastaReader(io::IO) = FastaReader{ST}(io)

function FastaReader(f::Function, filename::AbstractString, T::Type=ST)
    fr = FastaReader{T}(filename)
    try
        f(fr)
    finally
        close(fr)
    end
end

close(fr::FastaReader) = fr.own_f && close(fr.f)

function rewind(fr::FastaReader)
    seek(fr.f, 0)
    fr.is_eof = false
    fr.num_parsed = 0
    fr.rbuf_sz = 0
    fr.rbuf_pos = 0
    fr.lbuf_sz = 0
    fr.mbuf_sz = 0
    return
end

read_chunk_ll(fr::FastaReader, s::GZipStream) = gzread(s, pointer(fr.rbuffer), fasta_buffer_size)
read_chunk_ll(fr::FastaReader, s::IOStream) =
    ccall(:ios_readall, UInt, (Ptr{Void}, Ptr{Void}, UInt), fr.f.ios, fr.rbuffer, fasta_buffer_size)
function read_chunk_ll(fr::FastaReader, s::IO)
    ret = 0
    while !eof(fr.f) && ret < fasta_buffer_size
        ret += 1
        fr.rbuffer[ret] = read(fr.f, UInt8)
    end
    return ret
end

function read_chunk(fr::FastaReader)
    if fr.is_eof
        return
    end
    ret = read_chunk_ll(fr, fr.f)
    ret == -1 && error("read failure")
    fr.rbuf_sz = ret
    fr.rbuf_pos = 1
    if ret == 0
        fr.is_eof = true
    end
    return
end

function readline(fr::FastaReader)
    fr.lbuf_sz = 0
    found = false
    while !fr.is_eof
        if fr.rbuf_pos == 0
            read_chunk(fr::FastaReader)
        end
        i = fr.rbuf_pos
        cr = false
        while i <= fr.rbuf_sz
            c = fr.rbuffer[i]
            @compat if c == UInt8('\n')
                found = true
                break
            else
                cr = (c == UInt8('\r'))
            end
            i += 1
        end
        i -= 1 + cr
        chunk_len = i - fr.rbuf_pos + 1
        free_sbuf = length(fr.lbuffer) - fr.lbuf_sz
        gap = chunk_len - free_sbuf
        if gap > 0
            resize!(fr.lbuffer, length(fr.lbuffer) + gap)
        end

        #fr.lbuffer[fr.lbuf_sz + (1:chunk_len)] = fr.rbuffer[fr.rbuf_pos:i]
        copy!(fr.lbuffer, fr.lbuf_sz + 1, fr.rbuffer, fr.rbuf_pos, chunk_len)
        fr.lbuf_sz += chunk_len

        i += 2 + cr
        if i > fr.rbuf_sz
            i = 0
        end
        fr.rbuf_pos = i
        found && break
    end
    return
end

function start(fr::FastaReader)
    rewind(fr)
    readline(fr)
    if fr.lbuf_sz == 0
        error("empty FASTA file")
    end
    return
end
@compat done(fr::FastaReader, x::Void) = fr.is_eof
@compat function _next_step(fr::FastaReader)
    if fr.lbuffer[1] != UInt8('>')
        error("invalid FASTA file: description does not start with '>'")
    end
    if fr.lbuf_sz == 1
        error("invalid FASTA file: empty description")
    end
    if VERSION < v"0.5-"
        name = ascii(fr.lbuffer[2:fr.lbuf_sz])
    else
        name = String(fr.lbuffer[2:fr.lbuf_sz])
        isascii(name) || error("invalid non-ASCII description in FASTA file")
    end
    fr.mbuf_sz = 0
    while true
        readline(fr)
        if fr.lbuf_sz == 0 || fr.lbuffer[1] == UInt8('>')
            break
        end
        gap = fr.lbuf_sz - (length(fr.mbuffer) - fr.mbuf_sz)
        if gap > 0
            resize!(fr.mbuffer, length(fr.mbuffer) + gap)
        end
        #fr.mbuffer[fr.mbuf_sz + (1:fr.lbuf_sz)] = fr.lbuffer[1:fr.lbuf_sz]
        copy!(fr.mbuffer, fr.mbuf_sz + 1, fr.lbuffer, 1, fr.lbuf_sz)
        fr.mbuf_sz += fr.lbuf_sz
    end
    return name
end
function _next(fr::FastaReader{Vector{UInt8}})
    name = _next_step(fr)
    fr.num_parsed += 1
    return (name, fr.mbuffer[1:fr.mbuf_sz])
end
if VERSION < v"0.5-"
    function _next(fr::FastaReader{ASCIIString})
        name = _next_step(fr)
        out_str = ccall(:jl_pchar_to_string, ByteString, (Ptr{UInt8},Int), fr.mbuffer, fr.mbuf_sz)
        fr.num_parsed += 1
        return (name, out_str)
    end
else
    function _next(fr::FastaReader{String})
        name = _next_step(fr)
        out_str = ccall(:jl_pchar_to_string, Ref{String}, (Ptr{UInt8},Int), fr.mbuffer, fr.mbuf_sz)
        fr.num_parsed += 1
        return (name, out_str)
    end
end
function _next{T}(fr::FastaReader{T})
    name = _next_step(fr)
    fr.num_parsed += 1
    return (name, convert(T, fr.mbuffer[1:fr.mbuf_sz]))
end

@compat next(fr::FastaReader, x::Void) = (_next(fr), nothing)

function readall(fr::FastaReader)
    ret = Any[]
    for item in fr
        push!(ret, item)
    end
    return ret
end

function readentry(fr::FastaReader)
    fr.is_eof && throw(EOFError())
    if fr.num_parsed == 0
        readline(fr)
        if fr.lbuf_sz == 0
            error("empty FASTA file")
        end
    end
    item, _ = next(fr, nothing)
    return item
end

eof(fr::FastaReader) = fr.is_eof

function show{T}(io::IO, fr::FastaReader{T})
    print(io, "FastaReader(input=\"$(fr.f)\", out_type=$T, num_parsed=$(fr.num_parsed), eof=$(fr.is_eof))")
end

function readfasta(filename::AbstractString, T::Type=ST)
    FastaReader(filename, T) do fr
        readall(fr)
    end
end
readfasta(io::IO, T::Type=ST) = readall(FastaReader{T}(io))

type FastaWriter
    f::IO
    in_seq::Bool
    entry_chars::Int
    desc_chars::Int
    parsed_nl::Bool
    pos::Int
    entry::Int
    own_f::Bool
    at_start::Bool
    function FastaWriter(io::IO)
        fw = new(io, false, 0, 0, false, 0, 1, false, true)
        finalizer(fw, close)
        return fw
    end
    function FastaWriter(filename::AbstractString, mode::AbstractString = "w")
        if endswith(filename, ".gz")
            of = gzopen
        else
            of = open
        end
        fw = new(of(filename, mode), false, 0, 0, false, 0, 1, true, true)
        finalizer(fw, close)
        return fw
    end
end

FastaWriter() = FastaWriter(STDOUT)

function FastaWriter(f::Function, args...)
    fw = FastaWriter(args...)
    try
        f(fw)
    finally
        close(fw)
    end
end

function write(fw::FastaWriter, c)
    ch = convert(Char, c)
    isascii(ch) || error("invalid (non-ASCII) character: $c (entry $(fw.entry) of FASTA input)")
    if ch == '\n' && !fw.at_start
        fw.parsed_nl = true
        if !fw.in_seq
            fw.desc_chars == 1 && error("empty description (entry $(fw.entry) of FASTA input")
            write(fw.f, '\n')
            fw.pos = 0
            fw.in_seq = true
        end
    end
    isspace(ch) && (fw.at_start || fw.in_seq || fw.desc_chars <= 1) && return
    fw.at_start && ch != '>' && error("no desctiption given (entry $(fw.entry) of FASTA input")
    fw.at_start = false
    if fw.parsed_nl
        @assert fw.in_seq
        if ch == '>'
            fw.entry_chars > 0 || error("description must span a single line (entry $(fw.entry) of FASTA input)")
            write(fw.f, '\n')
            fw.in_seq = false
            fw.pos = 0
            fw.entry += 1
            fw.entry_chars = 0
            fw.desc_chars = 0
        end
    elseif fw.in_seq && ch == '>'
        error("character '>' not allowed in sequence data (entry $(fw.entry) of FASTA input)")
    end
    if fw.pos == 80
        if !fw.in_seq
            warn("description line longer than 80 characters (entry $(fw.entry) of FASTA input)")
        else
            write(fw.f, '\n')
            fw.pos = 0
        end
    end
    write(fw.f, ch)
    fw.pos += 1
    if fw.in_seq
        fw.entry_chars += 1
    else
        fw.desc_chars += 1
    end
    fw.parsed_nl = false
    return
end

function write(fw::FastaWriter, s::Vector)
    for c in s
        write(fw, c)
    end
end

function write(fw::FastaWriter, s::AbstractString)
    for c in s
        write(fw, c)
    end
    write(fw, '\n')
end

function writeentry(fw::FastaWriter, desc::AbstractString, seq)
    !fw.at_start && write(fw, '\n')
    if VERSION < v"0.5-"
        desc = strip(ascii(desc))
    else
        desc = strip(String(desc))
        isascii(desc) || error("description must be ASCCII (entry $(fw.entry+1) of FASTA input)")
    end
    if search(desc, '\n') != 0
        error("newlines are not allowed within description (entry $(fw.entry+1) of FASTA input)")
    end
    write(fw, '>')
    write(fw, desc)
    write(fw, '\n')
    #write(fw, seq)
    #write(fw, '\n')
    fw.entry_chars = writefastaseq(fw.f, seq, fw.entry, false)
    fw.in_seq = true
    fw.parsed_nl = false
    fw.pos = 0
    fw.entry_chars > 0 || error("empty sequence data (entry $(fw.entry) of FASTA input)")
    return
end

function close(fw::FastaWriter)
    try
        write(fw.f, '\n')
        flush(fw.f)
    catch err
        isa(err, EOFError) || rethrow(err)
    end
    fw.pos = 0
    fw.parsed_nl = true
    fw.own_f && close(fw.f)
    return
end

function show(io::IO, fw::FastaWriter)
    print(io, "FastaWriter(input=\"$(fw.f)\", entry=$(fw.entry)")
end

function writefastaseq(io::IO, seq, entry::Int, nl::Bool = true)
    i = 0
    entry_chars = 0
    for c in seq
        if i == 80
            write(io, '\n')
            i = 0
        end
        ch = convert(Char, c)
        isascii(ch) || error("invalid (non-ASCII) character: $c (entry $entry of FASTA input)")
        isspace(ch) && continue
        ch != '>' || error("character '>' not allowed in sequence data (entry $entry of FASTA input)")
        write(io, ch)
        i += 1
        entry_chars += 1
    end
    nl && write(io, '\n')
    return entry_chars
end

function writefasta(io::IO, data)
    entry = 0
    for (desc, seq) in data
        entry += 1
        if VERSION < v"0.5-"
            desc = strip(ascii(desc))
        else
            desc = strip(String(desc))
            isascii(desc) || error("description must be ASCCII (entry $entry of FASTA input)")
        end
        if isempty(desc)
            error("empty description (entry $entry of FASTA input")
        end
        if search(desc, '\n') != 0
            error("newlines are not allowed within description (entry $entry of FASTA input)")
        end
        if length(desc) > 79
            warn("description line longer than 80 characters (entry $entry of FASTA input)")
        end
        println(io, ">", desc)
        entry_chars = writefastaseq(io, seq, entry)
        entry_chars > 0 || error("empty sequence data (entry $entry of FASTA input)")
    end
end
writefasta(data) = writefasta(STDOUT, data)

function writefasta(filename::AbstractString, data, mode::AbstractString = "w")
    if endswith(filename, ".gz")
        of = gzopen
    else
        of = open
    end
    of(filename, mode) do f
        writefasta(f, data)
    end
end

end
