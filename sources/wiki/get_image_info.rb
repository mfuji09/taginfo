#!/usr/bin/env ruby
# coding: utf-8
#------------------------------------------------------------------------------
#
#  get_image_info.rb [DIR]
#
#------------------------------------------------------------------------------
#
#  Gets meta information about images from the OSM wiki.
#
#  Reads the list of all images used in Key: and Tag: pages from the local
#  database and requests meta information (width, height, mime type, URL, ...)
#  for those images. Writes this data into the wiki_images table.
#
#  The database must be in DIR or in the current directory, if no directory
#  was given on the command line.
#
#------------------------------------------------------------------------------
#
#  Copyright (C) 2013-2017  Jochen Topf <jochen@topf.org>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License along
#  with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#------------------------------------------------------------------------------

require 'pp'

require 'net/http'
require 'uri'
require 'json'
require 'sqlite3'

require 'mediawikiapi.rb'

#------------------------------------------------------------------------------

dir = ARGV[0] || '.'
database = SQLite3::Database.new(dir + '/taginfo-wiki.db')
database.results_as_hash = true

#------------------------------------------------------------------------------

api = MediaWikiAPI::API.new

image_titles = database.execute("SELECT DISTINCT(image) AS title FROM wikipages WHERE image IS NOT NULL AND image != '' UNION SELECT DISTINCT(osmcarto_rendering) AS title FROM wikipages WHERE osmcarto_rendering IS NOT NULL AND osmcarto_rendering != '' UNION SELECT DISTINCT(image) AS title FROM relation_pages WHERE image IS NOT NULL AND image != ''").
                    map{ |row| row['title'] }.
                    select{ |title| title.match(%r{^(file|image):}i) }.
                    sort.
                    uniq

database.transaction do |db|
    puts "Found #{ image_titles.size } different image titles"

    images_added = {}

    until image_titles.empty?
        some_titles = image_titles.slice!(0, 10)
        puts "Get image info for: #{ some_titles.join(' ') }"

        begin
            data = api.query(:prop => 'imageinfo', :iiprop => 'url|size|mime', :titles => some_titles.join('|'), :iiurlwidth => 10, :iiurlheight => 10)

            if !data['query']
                puts "Wiki API call failed (no 'query' field):"
                pp data
                next
            end

            normalized = data['query']['normalized']
            if normalized
                normalized.each do |n|
                    db.execute('UPDATE wikipages SET image=? WHERE image=?', [n['to'], n['from']])
                    db.execute('UPDATE relation_pages SET image=? WHERE image=?', [n['to'], n['from']])
                end
            end

            if !data['query']['pages']
                puts "Wiki API call failed (no 'pages' field):"
                pp data
                next
            end

            data['query']['pages'].each do |k,v|
                if v['imageinfo'] && ! images_added[v['title']]
                    info = v['imageinfo'][0]
                    if info['thumburl'] && info['thumburl'].match(%r{^(.*/)[0-9]{1,4}(px-.*)$})
                        prefix = $1
                        suffix = $2
                        prefix.sub!('http:', 'https:')
                    else
                        prefix = nil
                        suffix = nil
                        puts "Wrong thumbnail format: '#{info['thumburl']}'"
                    end

                    info['url'].sub!('http:', 'https:')

                    # The OSM wiki reports the wrong thumbnail URL for images
                    # transcluded from Wikimedia Commons. This fixes those
                    # URLs.
                    if prefix && info['url'].match(%r{^https://upload\.wikimedia\.org/wikipedia/commons})
                        prefix.sub!('https://wiki.openstreetmap.org/w/images', 'https://upload.wikimedia.org/wikipedia/commons')
                    end

                    images_added[v['title']] = 1
                    db.execute("INSERT INTO wiki_images (image, width, height, size, mime, image_url, thumb_url_prefix, thumb_url_suffix) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
                        v['title'],
                        info['width'],
                        info['height'],
                        info['size'],
                        info['mime'],
                        info['url'],
                        prefix,
                        suffix
                    ])
                end
            end
        rescue => ex
            puts "Wiki API call error: #{ex.message}"
            pp data
        end
    end
end


#-- THE END -------------------------------------------------------------------
