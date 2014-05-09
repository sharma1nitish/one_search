require 'rubygems'
require 'bundler/setup'

require 'open-uri'
require 'nokogiri'
require 'yaml'
require 'webrobots'
require 'fast-stemmer'
require 'wirb'
require 'awesome_print'
require 'logger'
require 'data_mapper'
require_relative 'models.rb'

#Configuring seed file
SEED = File.join(Dir.pwd, 'seeds.yaml')

#Configuring database
DataMapper.setup(:default, "sqlite:///#{File.join(Dir.pwd, 'data.db')}")

#Initializing logger
logger = Logger.new STDOUT
logger.level = Logger::WARN

RESTRICTED_TYPES = %w(.pdf .doc .docx .xls .xlsx .ppt .pptx .json .mpg .mpeg .avi .wmv .xml .mp3 .m4a .jpg .gif .png .bmp .zip .rar .7z .asc)

# Sanitizes a URL
def sanitize(site)
  url = URI(site)
  begin
    url = URI::HTTP.build({ host: url.to_s }) if url.instance_of? URI::Generic 
  rescue URI::InvalidComponentError => e
    logger.warn("#{site} is not a valid URL.")
  end
  return url.to_s
end

class URI::InvalidURL < Exception; end

robots = WebRobots.new('AnkurBot/1.0')

def scrub(link)
  unless link.nil?
    link = link.scan(/.*(?=#)/)[0] if link.match(/#/)
    return nil if RESTRICTED_TYPES.include? File.extname(link)
    URI.join(URI.escape(link)).normalize.to_s
  end
end

COMMON_WORDS = File.read('common_words').split("\n")

def add_to_index(url, doc)
  # Indexing
  link = Link.first_or_new(url: url)
  if link.indexable?
    puts "  Indexing #{url} at #{Time.now} <--"
    #doc = Nokogiri::HTML(open(url))
    link.locations.destroy unless link.new?
    body = doc.at('body')
    title = doc.at('title')
    body.search('script, noscript').remove
    words = body.text.gsub(/[\d]|[^\w\s]/, '').split.map(&:downcase).reject do |word|
      COMMON_WORDS.include?(word) or word.size > 25
    end.map(&:stem).each_with_index do |word, index|
      loc = Location.new(position: index)
      loc.word = Word.first_or_new(stem: word)
      loc.link = link
      puts "    --> Writing word - #{word} at index #{index}"
      loc.save
    end
    puts "    --> Writing title - #{title.text}"
    link.title = title.text
    link.save
    true
  else
    false
  end
end


#Traverse the seeds and start crawling ...
loop do
  accumulated_links = []
  YAML.load(File.open(SEED)).map do |site|
    begin
      site = scrub(sanitize(site))
    rescue
      next
    end
    puts "Found the #{site} <-- Initializing procedure ..."
    link = Link.first_or_new(url: site)
    if link.new? or link.indexable?
      begin
        #if link.new? or link.indexable?
        doc = Nokogiri::HTML(open(site))
        add_to_index(site, doc)
        puts "  Now crawling the #{site} for further links... <--"
        links = doc.css('a').map do |link|
          if link['href']
            begin
              link = link['href']
              link = URI.join(site, link).to_s if link.start_with? "/"
              link = scrub(link)
              #link = scrub(URI.join(site, link).to_s) if link.start_with?("/")
              link ? (robots.allowed?(URI(link)) ? link : nil) : link
              accumulated_links << link

              puts " -> #{link}"
              #rescue OpenURI::HTTPError => e
              #  puts "Couldn't connect - #{e.message}"
              #  nil
              #rescue Timeout::Error => e
              #  puts "Request timed out! - #{e.message}"
              #  nil
            rescue Exception => e
              puts "Something went wrong in here - #{e.inspect} - #{e.message}"
              nil
            end

          else nil
          end
        end.uniq.compact

        p links
      rescue OpenURI::HTTPError => e
        puts "Couldn't connect - #{e.message}"
      rescue Timeout::Error => e
        puts "Request timed out! - #{e.message}"
      rescue Exception => e
        puts "Something went wrong - #{e.inspect} - #{e.message}"
      end
      links ||= []
    else
      []
    end
  end
  accumulated_links = accumulated_links.uniq.compact

  File.open(SEED, 'wb') do |file|
    file.puts("---")
    accumulated_links.each { |link| file.puts "- #{link}" }
  end

end
