# Description:
#   Interact with your Jenkins CI server
#   based on https://github.com/github/hubot-scripts/blob/master/src/scripts/jenkins.coffee
#   but this version allows individual users to authenticate
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_JENKINS_URL
#   HUBOT_JENKINS_CRYPTO_SECRET - secret for encrypting/decrypting user credential
#
# Commands:
#   hubot jenkins b <jobNumber> - builds the job specified by jobNumber. List jobs to get number.
#   hubot jenkins build <job> - builds the specified Jenkins job
#   hubot jenkins build <job>, <params> - builds the specified Jenkins job with parameters as key=value&key2=value2
#   hubot jenkins list <filter> - lists Jenkins jobs
#   hubot jenkins describe <job> - Describes the specified Jenkins job
#   hubot jenkins last <job> - Details about the last build for the specified Jenkins job
#   hubot jenkins set auth <user:apitoken> - Set jenkins credentials (get token from https://<jenkins>/user/<user>/configure)
#
# Author:
#   dougcole
#   benwtr

querystring = require 'querystring'
crypto = require 'crypto'

# Holds a list of jobs, so we can trigger them with a number
# instead of the job's name. Gets populated on when calling
# list.
jobList = []

crypto_secret = process.env.HUBOT_JENKINS_CRYPTO_SECRET

encrypt = (text) ->
  cipher = crypto.createCipher('aes-256-cbc', crypto_secret)
  crypted = cipher.update(text, 'utf8', 'hex')
  crypted += cipher.final('hex')
  crypted

decrypt = (text) ->
  deciper = crypto.createDecipher('aes-256-cbc', crypto_secret)
  decrypted = deciper.update(text, 'hex', 'utf8')
  decrypted += deciper.final('utf8')
  decrypted

jenkinsUserCredentials = (msg) ->
  user_id = msg.envelope.user.id
  decrypt(msg.robot.brain.data.users[user_id].jenkins_auth)

jenkinsBuildById = (msg) ->
  # Switch the index with the job name
  job = jobList[parseInt(msg.match[1]) - 1]

  if job
    msg.match[1] = job
    jenkinsBuild(msg)
  else
    msg.reply "I couldn't find that job. Try `jenkins list` to get a list."

jenkinsBuild = (msg, buildWithEmptyParameters) ->
  url = process.env.HUBOT_JENKINS_URL
  job = querystring.escape msg.match[1]
  params = msg.match[3]
  command = if buildWithEmptyParameters then "buildWithParameters" else "build"
  path = if params then "#{url}/job/#{job}/buildWithParameters?#{params}" else "#{url}/job/#{job}/#{command}"

  req = msg.http(path)

  auth = new Buffer(jenkinsUserCredentials(msg)).toString('base64')
  req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.post() (err, res, body) ->
    if err
      msg.reply "Jenkins says: #{err}"
    else if 200 <= res.statusCode < 400 # Or, not an error code.
      msg.reply "(#{res.statusCode}) Build started for #{job} #{url}/job/#{job}"
    else if 400 == res.statusCode
      jenkinsBuild(msg, true)
    else
      msg.reply "Jenkins says: Status #{res.statusCode} #{body}"

jenkinsDescribe = (msg) ->
  url = process.env.HUBOT_JENKINS_URL
  job = msg.match[1]

  path = "#{url}/job/#{job}/api/json"

  req = msg.http(path)

  auth = new Buffer(jenkinsUserCredentials(msg)).toString('base64')
  req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.get() (err, res, body) ->
    if err
      msg.send "Jenkins says: #{err}"
    else
      response = ""
      try
        content = JSON.parse(body)
        response += "JOB: #{content.displayName}\n"
        response += "URL: #{content.url}\n"

        if content.description
          response += "DESCRIPTION: #{content.description}\n"

        response += "ENABLED: #{content.buildable}\n"
        response += "STATUS: #{content.color}\n"

        tmpReport = ""
        if content.healthReport.length > 0
          for report in content.healthReport
            tmpReport += "\n  #{report.description}"
        else
          tmpReport = " unknown"
        response += "HEALTH: #{tmpReport}\n"

        parameters = ""
        for item in content.actions
          if item.parameterDefinitions
            for param in item.parameterDefinitions
              tmpDescription = if param.description then " - #{param.description} " else ""
              tmpDefault = if param.defaultParameterValue then " (default=#{param.defaultParameterValue.value})" else ""
              parameters += "\n  #{param.name}#{tmpDescription}#{tmpDefault}"

        if parameters != ""
          response += "PARAMETERS: #{parameters}\n"

        msg.send response

        if not content.lastBuild
          return

        path = "#{url}/job/#{job}/#{content.lastBuild.number}/api/json"
        req = msg.http(path)

        auth = new Buffer(jenkinsUserCredentials(msg)).toString('base64')
        req.headers Authorization: "Basic #{auth}"

        req.header('Content-Length', 0)
        req.get() (err, res, body) ->
          if err
            msg.send "Jenkins says: #{err}"
          else
            response = ""
            try
              content = JSON.parse(body)
              console.log(JSON.stringify(content, null, 4))
              jobstatus = content.result || 'PENDING'
              jobdate = new Date(content.timestamp);
              response += "LAST JOB: #{jobstatus}, #{jobdate}\n"

              msg.send response
            catch error
              msg.send error

      catch error
        msg.send error

jenkinsLast = (msg) ->
  url = process.env.HUBOT_JENKINS_URL
  job = msg.match[1]

  path = "#{url}/job/#{job}/lastBuild/api/json"

  req = msg.http(path)

  auth = new Buffer(jenkinsUserCredentials(msg)).toString('base64')
  req.headers Authorization: "Basic #{auth}"

  req.header('Content-Length', 0)
  req.get() (err, res, body) ->
    if err
      msg.send "Jenkins says: #{err}"
    else
      response = ""
      try
        content = JSON.parse(body)
        response += "NAME: #{content.fullDisplayName}\n"
        response += "URL: #{content.url}\n"

        if content.description
          response += "DESCRIPTION: #{content.description}\n"

        response += "BUILDING: #{content.building}\n"

        msg.send response

jenkinsAuth = (msg) ->
  user_id = msg.envelope.user.id
  credentials = msg.match[1].trim()
  msg.robot.brain.data.users[user_id].jenkins_auth = encrypt(credentials)
  msg.send "Saved jenkins credentials for #{user_id}"

jenkinsList = (msg) ->
  url = process.env.HUBOT_JENKINS_URL
  filter = new RegExp(msg.match[2], 'i')
  req = msg.http("#{url}/api/json")

  auth = new Buffer(jenkinsUserCredentials(msg)).toString('base64')
  req.headers Authorization: "Basic #{auth}"

  req.get() (err, res, body) ->
    response = ""
    if err
      msg.send "Jenkins says: #{err}"
    else
      try
        content = JSON.parse(body)
        for job in content.jobs
          # Add the job to the jobList
          index = jobList.indexOf(job.name)
          if index == -1
            jobList.push(job.name)
            index = jobList.indexOf(job.name)

          state = if job.color == "red" then "FAIL" else "PASS"
          if filter.test job.name
            response += "[#{index + 1}] #{state} #{job.name}\n"
        msg.send response
      catch error
        msg.send error



module.exports = (robot) ->
  robot.respond /j(?:enkins)? build ([\w\.\-_ ]+)(, (.+))?/i, (msg) ->
    jenkinsBuild(msg, false)

  robot.respond /j(?:enkins)? b (\d+)/i, (msg) ->
    jenkinsBuildById(msg)

  robot.respond /j(?:enkins)? list( (.+))?/i, (msg) ->
    jenkinsList(msg)

  robot.respond /j(?:enkins)? describe (.*)/i, (msg) ->
    jenkinsDescribe(msg)

  robot.respond /j(?:enkins)? last (.*)/i, (msg) ->
    jenkinsLast(msg)

  robot.respond /j(?:enkins)? set auth (.*)/i, (msg) ->
    jenkinsAuth(msg)

  robot.jenkins = {
    list: jenkinsList,
    build: jenkinsBuild
    describe: jenkinsDescribe
    last: jenkinsLast
    auth: jenkinsAuth
  }
