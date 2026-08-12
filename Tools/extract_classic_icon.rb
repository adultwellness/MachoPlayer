#!/usr/bin/env ruby
# Wraps classic icl8 + ICN# resources in an icns container that modern image
# tools can decode. This preserves the exact 2002 pixel art and mask.

abort "usage: extract_classic_icon.rb RESOURCE_FILE ID OUTPUT.icns" unless ARGV.length == 3
resource_file, id_text, output = ARGV
resource_id = Integer(id_text)

def resource_bytes(resource_file, type, resource_id)
  source = IO.popen(["DeRez", resource_file, "-only", type], "rb", &:read)
  pattern = /^data '#{Regexp.escape(type)}' \(#{resource_id}(?:,|\)).*?^};/m
  block = source.match(pattern)&.[](0)
  return nil if block.nil?
  hex = block.scan(/\$"([0-9A-Fa-f ]+)"/).flatten.join.delete(" ")
  [hex].pack("H*")
end

small_color = resource_bytes(resource_file, "ics8", resource_id)
small_mask = resource_bytes(resource_file, "ics#", resource_id)
if small_color && small_mask
  resources = [["ics8", small_color], ["ics#", small_mask]]
else
  color = resource_bytes(resource_file, "icl8", resource_id)
  mask = resource_bytes(resource_file, "ICN#", resource_id)
  abort "missing icon-suite resource #{resource_id}" unless color && mask
  resources = [["icl8", color], ["ICN#", mask]]
end
chunks = resources.map do |type, data|
  type + [data.bytesize + 8].pack("N") + data
end.join
File.binwrite(output, "icns" + [chunks.bytesize + 8].pack("N") + chunks)
