require 'rest-client'
require 'json'
require 'date'
require 'csv'
require 'yaml'

CONFIG = YAML.load_file('./secrets/secrets.yml')

date = Date.today-2

file_date = date.strftime("%Y%m")
csv_file_name = "reviews_#{CONFIG["package_name"]}_#{file_date}.csv"
system "BOTO_PATH=./secrets/.boto gsutil/gsutil cp -r gs://#{CONFIG["app_repo"]}/reviews/#{csv_file_name} ."
system "BOTO_PATH=./secrets/.boto gsutil/gsutil cp gs://play_public/supported_devices.csv ."

class Slack
  def self.notify(message)
    if CONFIG["proxy"]
      RestClient.proxy = CONFIG["proxy"]
    end
    RestClient.post CONFIG["slack_url"], {
      payload:
      { text: message }.to_json
    },
    content_type: :json,
    accept: :json
  end
end

class Review
  def self.collection
    @collection ||= []
  end

  def self.send_reviews_from_date(date)
    message = collection.select do |r|
      r.submitted_at > date && (r.title || r.text)
    end.sort_by do |r|
      r.submitted_at
    end.map do |r|
      r.build_message
    end.join("\n")


    if message != ""
      Slack.notify(message)
    else
      print "No new reviews\n"
    end
  end

  attr_accessor :text, :title, :submitted_at, :original_subitted_at, :rate, :device, :url, :version, :edited

  def initialize data = {}
    @text = data[:text] ? data[:text].to_s.encode("utf-8") : nil
    @title = data[:title] ? "*#{data[:title].to_s.encode("utf-8")}*\n" : nil

    @submitted_at = DateTime.parse(data[:submitted_at].encode("utf-8"))
    @original_subitted_at = DateTime.parse(data[:original_subitted_at].encode("utf-8"))

    @rate = data[:rate].encode("utf-8").to_i
    @device = data[:device] ? data[:device].to_s.encode("utf-8") : "Unavailable"
    @url = data[:url].to_s.encode("utf-8")
    @version = data[:version].to_s.encode("utf-8")
    @edited = data[:edited]
  end

  def notify_to_slack
    if text || title
      message = "*Rating: #{rate}* | version: #{version} | subdate: #{submitted_at}\n #{[title, text].join(" ")}\n <#{url}|Google Play Reviews>"
      Slack.notify(message)
    end
  end

  def build_message
    date = if edited
             "subdate: #{original_subitted_at.strftime("%d.%m.%Y at %I:%M%p")}, edited at: #{submitted_at.strftime("%d.%m.%Y at %I:%M%p")}"
           else
             "subdate: #{submitted_at.strftime("%d.%m.%Y at %I:%M%p")}"
           end

    stars = rate.times.map{"★"}.join + (5 - rate).times.map{"☆"}.join

    marketingName = find_marketing_name(device)

    [
      "\n\n#{stars}",
      "Version: #{version} | #{date} | Device: #{device} - #{marketingName}",
      "#{[title, text].join(" ")}",
      "<#{url}|Google Play Reviews>"
    ].join("\n")
  end
end

def find_marketing_name(device)

  retailBrands = Array.new
  marketingNames = Array.new
  models = Array.new

  CSV.foreach("supported_devices.csv", encoding: 'bom|utf-16le', headers: true) do | column |

      retailBranding = column[0].nil? ? "Unavailable" : column[0].force_encoding('utf-16le').encode('utf-8')
      marketingName = column[1].nil? ? "Unavailable" : column[1].force_encoding('utf-16le').encode('utf-8')
      playDevice = column[2].nil? ? "Unavailable" : column[2].force_encoding('utf-16le').encode('utf-8')
      model = column[3].nil? ? "Unavailable" : column[3].force_encoding('utf-16le').encode('utf-8')

      if device.casecmp(playDevice) == 0
        if !(retailBrands.any?{ |s| s.casecmp(retailBranding)==0})
          retailBrands.push(retailBranding)
        end
        if !(marketingNames.any?{ |s| s.casecmp(marketingName)==0})
          marketingNames.push(marketingName)
        end
        models.push(model)
      end

  end

  return retailBrands.join("/") + " - " + marketingNames.join("/") + " - " + models.join("/")
end

CSV.foreach(csv_file_name, encoding: 'bom|utf-16le', headers: true) do |row|
  # If there is no reply - push this review
  if row[11].nil?
    Review.collection << Review.new({
      text: row[10],
      title: row[9],
      submitted_at: row[6],
      edited: (row[4] != row[6]),
      original_subitted_at: row[4],
      rate: row[8],
      device: row[3],
      url: row[14],
      version: row[1],
    })
  end
end

Review.send_reviews_from_date(date)
