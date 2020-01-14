username = "GsmToday" # GitHub 用户名
token = "6efc092154c7e598dcef58f65943089bfcfee746"  # GitHub Token
repo_name = "blog-comments" # 存放 issues
sitemap_url = "http://localhost:4000/sitemap.xml" # sitemap
kind = "Gitalk" # "Gitalk" or "gitment"

require 'open-uri'
require 'faraday'
require 'active_support'
require 'active_support/core_ext'
require 'sitemap-parser'
require 'uri'
require 'digest'

sitemap = SitemapParser.new sitemap_url
urls = sitemap.to_a

conn = Faraday.new(:url => "https://api.github.com/repos/#{username}/#{repo_name}/issues") do |conn|
  conn.basic_auth(username, token)
  conn.adapter  Faraday.default_adapter
end

urls.each_with_index do |url, index|
  title = open(url).read.scan(/<title>(.*?)<\/title>/).first.first.force_encoding('UTF-8')
  uri = URI::parse(url)  
  req_uri = uri.request_uri
  md5 = Digest::MD5.hexdigest req_uri[1,req_uri.size]
  response = conn.post do |req|
    req.body = { body: url, labels: [kind, md5], title: title }.to_json
  end
  puts response.body
  sleep 15 if index % 20 == 0
end
