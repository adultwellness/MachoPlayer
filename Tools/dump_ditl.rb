#!/usr/bin/env ruby
# Decodes the raw bytes of a classic Mac OS DITL resource from stdin.
# Usage: DeRez ... -only DITL | select-one-resource | ruby dump_ditl.rb

source = STDIN.read.force_encoding(Encoding::BINARY)
hex = source.scan(/\$"([0-9A-Fa-f ]+)"/).flatten.join.delete(" ")
abort "no resource data found" if hex.empty?
data = [hex].pack("H*")

offset = 0
read_u16 = lambda do
  value = data.byteslice(offset, 2).unpack1("n")
  offset += 2
  value
end
read_s16 = lambda do
  value = read_u16.call
  value >= 0x8000 ? value - 0x10000 : value
end

count = read_u16.call + 1
puts "items=#{count}"

count.times do |index|
  offset += 4 # item handle; zero in resource data
  top = read_s16.call
  left = read_s16.call
  bottom = read_s16.call
  right = read_s16.call
  type = data.getbyte(offset)
  offset += 1

  payload = ""
  case type & 0x7f
  when 4, 5, 6, 8, 16
    length = data.getbyte(offset)
    offset += 1
    payload = data.byteslice(offset, length).force_encoding("MacRoman").encode("UTF-8")
    offset += length
  when 7, 32, 64
    payload = read_u16.call.to_s
  end
  offset += 1 if offset.odd?

  puts format("%2d type=%3d rect=(%4d,%4d)-(%4d,%4d) %s", index + 1, type,
              left, top, right, bottom, payload.inspect)
end
