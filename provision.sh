#!/bin/bash
set -eux

domain=$(hostname --fqdn)

# use the local Jenkins user database.
config_authentication='jenkins'

echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >/etc/sudoers.d/env_keep_apt
chmod 440 /etc/sudoers.d/env_keep_apt
export DEBIAN_FRONTEND=noninteractive


#
# make sure the package index cache is up-to-date before installing anything.

apt-get update


# enable systemd-journald persistent logs.
sed -i -E 's,^#?(Storage=).*,\1persistent,' /etc/systemd/journald.conf
systemctl restart systemd-journald


#
# curl and add-apt-repository is required

apt-get install -y curl apt-transport-https software-properties-common python-software-properties


#
# add the Docker repository to APT sources

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"


#
# needs to be updated again because of the repo add above

apt-get update

#
# install docker-ce from default docker repo

apt-get install -y docker-ce


#
# daemon listen on a port
# NOTE: https://wiki.jenkins.io/display/JENKINS/Docker+Plugin

/etc/init.d/docker stop
dockerd -H :2375 &

#
# no sudo for docker vagrant user

usermod -aG docker vagrant


#
# install vim.

apt-get install -y --no-install-recommends vim

cat >~/.vimrc <<'EOF'
syntax on
set background=dark
set esckeys
set ruler
set laststatus=2
set nobackup
EOF


#
# configure the shell.

cat >~/.bash_history <<'EOF'
systemctl status nginx
systemctl restart nginx
systemctl status jenkins
systemctl restart jenkins
l
tail -f /var/log/jenkins/jenkins.log
tail -f /var/log/jenkins/access.log | grep -v ajax
cat /var/lib/jenkins/secrets/initialAdminPassword
cd /var/lib/jenkins
netstat -antp
jcli version
sudo -sHu jenkins
EOF

cat >~/.bashrc <<'EOF'
# If not running interactively, don't do anything
[[ "$-" != *i* ]] && return

export EDITOR=vim
export PAGER=less

alias l='ls -lF --color'
alias ll='l -a'
alias h='history 25'
alias j='jobs -l'
alias jcli="java -jar /var/cache/jenkins/war/WEB-INF/jenkins-cli.jar -s http://localhost:8080 -http -auth @$HOME/.jenkins-cli"
alias jgroovy='jcli groovy'
EOF

cat >~/.inputrc <<'EOF'
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOD": backward-word
"\eOC": forward-word
set show-all-if-ambiguous on
set completion-ignore-case on
EOF


#
# create a self-signed certificate.

pushd /etc/ssl/private
openssl genrsa \
    -out $domain-keypair.pem \
    2048 \
    2>/dev/null
chmod 400 $domain-keypair.pem
openssl req -new \
    -sha256 \
    -subj "/CN=$domain" \
    -key $domain-keypair.pem \
    -out $domain-csr.pem
openssl x509 -req -sha256 \
    -signkey $domain-keypair.pem \
    -extensions a \
    -extfile <(echo "[a]
        subjectAltName=DNS:$domain
        extendedKeyUsage=serverAuth
        ") \
    -days 365 \
    -in  $domain-csr.pem \
    -out $domain-crt.pem
popd


#
# install nginx as a proxy to Jenkins.

apt-get install -y --no-install-recommends nginx
cat >/etc/nginx/sites-available/jenkins <<EOF
ssl_session_cache shared:SSL:4m;
ssl_session_timeout 6h;
#ssl_stapling on;
#ssl_stapling_verify on;
server {
    listen 80;
    server_name _;
    return 301 https://$domain\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain;
    client_max_body_size 50m;

    ssl_certificate /etc/ssl/private/$domain-crt.pem;
    ssl_certificate_key /etc/ssl/private/$domain-keypair.pem;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    # see https://github.com/cloudflare/sslconfig/blob/master/conf
    # see https://blog.cloudflare.com/it-takes-two-to-chacha-poly/
    # see https://blog.cloudflare.com/do-the-chacha-better-mobile-performance-with-cryptography/
    # NB even though we have CHACHA20 here, the OpenSSL library that ships with Ubuntu 16.04 does not have it. so this is a nop. no problema.
    ssl_ciphers EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!aNULL:!MD5;
    add_header Strict-Transport-Security "max-age=31536000; includeSubdomains";

    access_log /var/log/nginx/$domain-access.log;
    error_log /var/log/nginx/$domain-error.log;

    # uncomment the following to debug errors and rewrites.
    #error_log /var/log/nginx/$domain-error.log debug;
    #rewrite_log on;

    location ~ "(/\\.|/\\w+-INF|\\.class\$)" {
        return 404;
    }

    location ~ "^/static/[0-9a-f]{8}/plugin/(.+/.+)" {
        alias /var/lib/jenkins/plugins/\$1;
    }

    location ~ "^/static/[0-9a-f]{8}/(.+)" {
        rewrite "^/static/[0-9a-f]{8}/(.+)" /\$1 last;
    }

    location /userContent/ {
        root /var/lib/jenkins;
    }

    location / {
        root /var/cache/jenkins/war;
        try_files \$uri @jenkins;
    }

    location @jenkins {
        proxy_pass http://127.0.0.1:8080;
        proxy_redirect default;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
rm /etc/nginx/sites-enabled/default
ln -s ../sites-available/jenkins /etc/nginx/sites-enabled/jenkins
systemctl restart nginx


#
# install Jenkins.

wget -qO- https://pkg.jenkins.io/debian-stable/jenkins.io.key | apt-key add -
echo 'deb http://pkg.jenkins.io/debian-stable binary/' >/etc/apt/sources.list.d/jenkins.list
apt-get update
apt-get install -y --no-install-recommends jenkins
bash -c 'while [ ! -s /var/lib/jenkins/secrets/initialAdminPassword ]; do sleep 1; done'
systemctl stop jenkins
apt-get install -y xmlstarlet
chmod 751 /var/cache/jenkins
pushd /var/lib/jenkins
# disable security.
# see https://wiki.jenkins-ci.org/display/JENKINS/Disable+security
xmlstarlet edit --inplace -u '/hudson/useSecurity' -v 'false' config.xml
xmlstarlet edit --inplace -d '/hudson/authorizationStrategy' config.xml
xmlstarlet edit --inplace -d '/hudson/securityRealm' config.xml
xmlstarlet edit --inplace -u '/hudson/installState/name' -v 'NEW' config.xml
# bind to localhost.
sed -i -E 's,^(JENKINS_ARGS="-.+),\1\nJENKINS_ARGS="$JENKINS_ARGS --httpListenAddress=127.0.0.1",' /etc/default/jenkins
# configure access log.
# NB this is useful for testing whether static files are really being handled by nginx.
sed -i -E 's,^(JENKINS_ARGS="-.+),\1\nJENKINS_ARGS="$JENKINS_ARGS --accessLoggerClassName=winstone.accesslog.SimpleAccessLogger --simpleAccessLogger.format=combined --simpleAccessLogger.file=/var/log/jenkins/access.log",' /etc/default/jenkins
sed -i -E 's,^(/var/log/jenkins/)jenkins.log,\1*.log,' /etc/logrotate.d/jenkins
# disable showing the wizard on the first access.
cp -p jenkins.install.UpgradeWizard.state jenkins.install.InstallUtil.lastExecVersion
popd
systemctl start jenkins
usermod -aG docker jenkins
bash -c 'while ! wget -q --spider http://localhost:8080/cli; do sleep 1; done;'


#
# configure Jenkins.

JCLI="java -jar /var/cache/jenkins/war/WEB-INF/jenkins-cli.jar -s http://localhost:8080"

function jcli {
    $JCLI -noKeyAuth "$@"
}

function jgroovy {
    jcli groovy "$@"
}

# customize.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
jgroovy = <<'EOF'
import hudson.model.Node.Mode
import jenkins.model.Jenkins

// disable usage statistics.
Jenkins.instance.noUsageStatistics = true

// do not run jobs on the master.
Jenkins.instance.numExecutors = 0
Jenkins.instance.mode = Mode.EXCLUSIVE

Jenkins.instance.save()
EOF

# set the jenkins url and administrator email.
# see http://javadoc.jenkins-ci.org/jenkins/model/JenkinsLocationConfiguration.html
jgroovy = <<EOF
import jenkins.model.JenkinsLocationConfiguration

c = JenkinsLocationConfiguration.get()
c.url = 'https://$domain'
c.adminAddress = 'Jenkins <jenkins@example.com>'
c.save()
EOF

# install and configure git.
apt-get install -y git-core
su jenkins -c bash <<'EOF'
set -eux
git config --global user.email 'jenkins@example.com'
git config --global user.name 'Jenkins'
git config --global push.default simple
git config --global core.autocrlf false
EOF

# install plugins.
# NB installing plugins is quite flaky, mainly because Jenkins (as-of 2.19.2)
#    does not retry their downloads. this will workaround it by (re)installing
#    until it works.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
# see http://javadoc.jenkins-ci.org/hudson/PluginManager.html
# see http://javadoc.jenkins.io/hudson/model/UpdateCenter.html
# see http://javadoc.jenkins.io/hudson/model/UpdateSite.Plugin.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins
Jenkins.instance.updateCenter.updateAllSites()
EOF
function install-plugins {
jgroovy = <<'EOF'
import jenkins.model.Jenkins

updateCenter = Jenkins.instance.updateCenter
pluginManager = Jenkins.instance.pluginManager

installed = [] as Set

def install(id) {
  plugin = updateCenter.getPlugin(id)

  plugin.dependencies.each {
    install(it.key)
  }

  if (!pluginManager.getPlugin(id) && !installed.contains(id)) {
    println("installing plugin ${id}...")
    pluginManager.install([id], false).each { it.get() }
    installed.add(id)
  }
}

[
    'cloudbees-folder',
    'git',
    'powershell',
    'xcode-plugin',
    'xunit',
].each {
  install(it)
}
EOF
}
while [[ -n "$(install-plugins)" ]]; do
    systemctl restart jenkins
    bash -c 'while ! wget -q --spider http://localhost:8080/cli; do sleep 1; done;'
done

# use the local SMTP MailHog server.
jgroovy = <<'EOF'
import jenkins.model.Jenkins

c = Jenkins.instance.getDescriptor('hudson.tasks.Mailer')
c.smtpHost = 'localhost'
c.smtpPort = '1025'
c.save()
EOF


#
# configure security.

# generate the SSH key-pair that jenkins master uses to communicates with the slaves.
su jenkins -c 'ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa'

# disable all JNLP agent protocols.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins

Jenkins.instance.agentProtocols = Jenkins.instance.agentProtocols.grep { !it.matches('^JNLP.+-connect$') }
Jenkins.instance.save()
EOF

# enable simple security.
# also create the vagrant user account. jcli will use this account from now on.
# see http://javadoc.jenkins-ci.org/hudson/security/HudsonPrivateSecurityRealm.html
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.tasks.Mailer

Jenkins.instance.securityRealm = new HudsonPrivateSecurityRealm(false)

u = Jenkins.instance.securityRealm.createAccount('vagrant', 'vagrant')
u.fullName = 'Vagrant'
u.addProperty(new Mailer.UserProperty('vagrant@example.com'))
u.save()

Jenkins.instance.authorizationStrategy = new FullControlOnceLoggedInAuthorizationStrategy(
  allowAnonymousRead: true)

Jenkins.instance.save()
EOF

# get the vagrant user api token.
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
# see http://javadoc.jenkins-ci.org/jenkins/security/ApiTokenProperty.html
# see https://jenkins.io/doc/book/managing/cli/
function jcli {
    $JCLI -http -auth vagrant:vagrant "$@"
}
jgroovy = >~/.jenkins-cli <<'EOF'
import hudson.model.User
import jenkins.security.ApiTokenProperty

u = User.current()
println sprintf("%s:%s", u.id, u.getProperty(ApiTokenProperty).apiToken)
EOF
chmod 400 ~/.jenkins-cli

# redefine jcli to use the vagrant api token.
function jcli {
    $JCLI -http -auth @$HOME/.jenkins-cli "$@"
}

# show which user is actually being used in jcli. this should show "vagrant".
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
jcli who-am-i
jgroovy = <<'EOF'
import hudson.model.User

u = User.current()
println sprintf("User id: %s", u.id)
println sprintf("User Full Name: %s", u.fullName)
u.allProperties.each { println sprintf("User property: %s", it) }; null
EOF

# create example accounts (when using jenkins authentication).
# see http://javadoc.jenkins-ci.org/hudson/model/User.html
# see http://javadoc.jenkins-ci.org/hudson/security/HudsonPrivateSecurityRealm.html
# see https://github.com/jenkinsci/mailer-plugin/blob/master/src/main/java/hudson/tasks/Mailer.java
if [ "$config_authentication" = 'jenkins' ]; then
jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.tasks.Mailer

[
    [id: "alice.doe",   fullName: "Alice Doe"],
    [id: "bob.doe",     fullName: "Bob Doe"  ],
    [id: "carol.doe",   fullName: "Carol Doe"],
    [id: "dave.doe",    fullName: "Dave Doe" ],
    [id: "eve.doe",     fullName: "Eve Doe"  ],
    [id: "frank.doe",   fullName: "Frank Doe"],
    [id: "grace.doe",   fullName: "Grace Doe"],
    [id: "henry.doe",   fullName: "Henry Doe"],
].each {
    u = Jenkins.instance.securityRealm.createAccount(it.id, "password")
    u.fullName = it.fullName
    u.addProperty(new Mailer.UserProperty(it.id+"@example.com"))
    u.save()
}
EOF
fi


#
# create artifacts that need to be shared with the other nodes.

mkdir -p /vagrant/tmp
pushd /vagrant/tmp
cp /var/lib/jenkins/.ssh/id_rsa.pub $domain-ssh-rsa.pub
cp /etc/ssl/private/$domain-crt.pem .
openssl x509 -outform der -in $domain-crt.pem -out $domain-crt.der
popd


#
# add the ubuntu slave node.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
# see http://javadoc.jenkins-ci.org/jenkins/model/Nodes.html
# see http://javadoc.jenkins-ci.org/hudson/slaves/DumbSlave.html
# see http://javadoc.jenkins-ci.org/hudson/model/Computer.html

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.slaves.DumbSlave
import hudson.slaves.CommandLauncher

node = new DumbSlave(
    "ubuntu",
    "/var/jenkins",
    new CommandLauncher("ssh ubuntu.jenkins.example.com /var/jenkins/bin/jenkins-slave"))
node.numExecutors = 3
node.labelString = "ubuntu 16.04 linux amd64"
Jenkins.instance.nodesObject.addNode(node)
Jenkins.instance.nodesObject.save()
EOF


#
# add the macos slave node.

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.slaves.DumbSlave
import hudson.slaves.CommandLauncher

node = new DumbSlave(
    "macos",
    "/var/jenkins",
    new CommandLauncher("ssh macos.jenkins.example.com /var/jenkins/bin/jenkins-slave"))
node.numExecutors = 3
node.labelString = "macos 10.12 amd64"
Jenkins.instance.nodesObject.addNode(node)
Jenkins.instance.nodesObject.save()
EOF


#
# create simple free style projects.
# see http://javadoc.jenkins-ci.org/jenkins/model/Jenkins.html
# see http://javadoc.jenkins-ci.org/hudson/model/FreeStyleProject.html
# see http://javadoc.jenkins-ci.org/hudson/model/Label.html
# see http://javadoc.jenkins-ci.org/hudson/tasks/Shell.html
# see http://javadoc.jenkins-ci.org/hudson/tasks/ArtifactArchiver.html
# see http://javadoc.jenkins-ci.org/hudson/tasks/BatchFile.html
# see http://javadoc.jenkins.io/plugin/mailer/hudson/tasks/Mailer.html
# see https://github.com/jenkinsci/powershell-plugin/blob/master/src/main/java/hudson/plugins/powershell/PowerShell.java
# see https://github.com/jenkinsci/git-plugin/blob/master/src/main/java/hudson/plugins/git/GitSCM.java
# see https://github.com/jenkinsci/git-plugin/blob/master/src/main/java/hudson/plugins/git/extensions/impl/CleanBeforeCheckout.java
# see https://github.com/jenkinsci/xunit-plugin/blob/master/src/main/java/org/jenkinsci/plugins/xunit/XUnitBuilder.java

# create the dump-environment folder to contain all of our dump jobs.
jgroovy = <<'EOF'
import jenkins.model.Jenkins
import com.cloudbees.hudson.plugins.folder.Folder

folder = new Folder(Jenkins.instance, 'dump-environment')
folder.save()

Jenkins.instance.add(folder, folder.name)
EOF

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.labels.LabelAtom
import hudson.tasks.Shell

folder = Jenkins.instance.getItem('dump-environment')

project = new FreeStyleProject(folder, 'linux')
project.assignedLabel = new LabelAtom('linux')
project.buildersList.add(new Shell(
'''\
cat /etc/lsb-release
uname -a
env
locale
id
'''))

folder.add(project, project.name)
EOF

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.labels.LabelAtom
import hudson.tasks.Shell

folder = Jenkins.instance.getItem('dump-environment')

project = new FreeStyleProject(folder, 'macos')
project.assignedLabel = new LabelAtom('macos')
project.buildersList.add(new Shell(
'''\
system_profiler SPSoftwareDataType
sw_vers
uname -a
env
locale
id
'''))

folder.add(project, project.name)
EOF

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.labels.LabelAtom
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import hudson.plugins.git.extensions.impl.CleanBeforeCheckout
import hudson.plugins.powershell.PowerShell
import hudson.tasks.ArtifactArchiver
import hudson.tasks.Mailer
import org.jenkinsci.plugins.xunit.XUnitBuilder
import org.jenkinsci.lib.dtkit.type.TestType
import org.jenkinsci.plugins.xunit.types.XUnitDotNetTestType
import org.jenkinsci.plugins.xunit.threshold.XUnitThreshold
import org.jenkinsci.plugins.xunit.threshold.FailedThreshold
import org.jenkinsci.plugins.xunit.threshold.SkippedThreshold

project = new FreeStyleProject(Jenkins.instance, 'MailBounceDetector')
project.assignedLabel = new LabelAtom('vs2017')
project.scm = new GitSCM('https://github.com/rgl/MailBounceDetector.git')
project.scm.branches = [new BranchSpec('*/master')]
project.scm.extensions.add(new CleanBeforeCheckout())
project.buildersList.add(new PowerShell(
'''\
$ErrorActionPreference = 'Stop'

MSBuild -m -p:Configuration=Release -t:restore -t:build
if ($LastExitCode) {
    Exit $LastExitCode
}

dir -Recurse */bin/*.Tests.dll | ForEach-Object {
    Push-Location $_.Directory
    Write-Host "Running the unit tests in $($_.Name)..."
    # NB maybe you should also use -skipautoprops
    OpenCover.Console.exe `
        -output:opencover-results.xml `
        -register:path64 `
        '-filter:+[*]* -[*.Tests*]* -[*]*.*Config -[xunit.*]*' `
        '-target:xunit.console.exe' `
        "-targetargs:$($_.Name) -nologo -noshadow -xml xunit-results.xml"
    ReportGenerator.exe `
        -reports:opencover-results.xml `
        -targetdir:coverage-report
    Compress-Archive `
        -CompressionLevel Optimal `
        -Path coverage-report/* `
        -DestinationPath coverage-report.zip
    Pop-Location
}
'''))
project.buildersList.add(new XUnitBuilder(
    [
        new XUnitDotNetTestType(
            '**/xunit-results.xml', // pattern
            false,  // skipNoTestFiles
            true,   // failIfNotNew
            true,   // deleteOutputFiles
            true    // stopProcessingIfError
        )
    ] as TestType[], // types
    [
        new FailedThreshold(
            '',     // unstableThreshold
            '',     // unstableNewThreshold
            '0',    // failureThreshold
            '',     // failureNewThreshold
        ),
        new SkippedThreshold(
            '',     // unstableThreshold
            '',     // unstableNewThreshold
            '',     // failureThreshold
            '',     // failureNewThreshold
        )
    ] as XUnitThreshold[], // thresholds
    1,      // thresholdMode
    '3000'  // testTimeMargin
))
project.publishersList.add(
    new ArtifactArchiver('**/*.nupkg,**/xunit-results.xml,**/opencover-results.xml,**/coverage-report.zip'))

project.publishersList.add(
    new Mailer('jenkins@example.com', true, false))

Jenkins.instance.add(project, project.name)
EOF

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.labels.LabelAtom
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import hudson.plugins.git.extensions.impl.CleanBeforeCheckout
import hudson.plugins.powershell.PowerShell

project = new FreeStyleProject(Jenkins.instance, 'example-dotnet-source-link')
project.assignedLabel = new LabelAtom('vs2017')
project.scm = new GitSCM('https://github.com/rgl/example-dotnet-source-link.git')
project.scm.branches = [new BranchSpec('*/master')]
project.scm.extensions.add(new CleanBeforeCheckout())
project.buildersList.add(new PowerShell(
'''\
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap {
    Write-Output "ERROR: $_"
    Write-Output (($_.ScriptStackTrace -split '\\r?\\n') -replace '^(.*)$','ERROR: $1')
    Write-Output (($_.Exception.ToString() -split '\\r?\\n') -replace '^(.*)$','ERROR EXCEPTION: $1')
    Exit 1
}
function exec([ScriptBlock]$externalCommand) {
    &$externalCommand
    if ($LASTEXITCODE) {
        throw "$externalCommand failed with exit code $LASTEXITCODE"
    }
}

cd ExampleLibrary
exec {dotnet build -v n -c Release}
exec {dotnet pack -v n -c Release --no-build -p:PackageVersion=0.0.1 --output .}

cd ../ExampleApplication
exec {dotnet build -v n -c Release}
exec {dotnet sourcelink print-urls bin/Release/netcoreapp2.0/ExampleApplication.dll}
exec {dotnet sourcelink print-json bin/Release/netcoreapp2.0/ExampleApplication.dll | ConvertFrom-Json | ConvertTo-Json -Depth 100}
exec {dotnet sourcelink print-documents bin/Release/netcoreapp2.0/ExampleApplication.dll}
dotnet run
# force a success exit code because dotnet run is expected to fail due
# to an expected unhandled exception being raised by the application.
$LASTEXITCODE = 0
'''))

Jenkins.instance.add(project, project.name)
EOF

jgroovy = <<'EOF'
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.labels.LabelAtom
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.GitSCM
import hudson.plugins.git.extensions.impl.CleanBeforeCheckout
import hudson.tasks.Shell
import hudson.tasks.ArtifactArchiver

project = new FreeStyleProject(Jenkins.instance, 'minimal-cocoa-app')
project.assignedLabel = new LabelAtom('macos')
project.scm = new GitSCM('https://github.com/rgl/minimal-cocoa-app.git')
project.scm.branches = [new BranchSpec('*/master')]
project.scm.extensions.add(new CleanBeforeCheckout())
project.buildersList.add(new Shell(
'''\
make build
'''))
project.buildersList.add(new Shell(
'''\
# package as a tarball
tar czf minimal-cocoa-app.app.tgz minimal-cocoa-app.app

# package as a dmg
[[ -d make_dmg ]] || git clone https://github.com/rgl/make_dmg.git
cd make_dmg
[[ -f background.png ]] || curl -sLO http://bitbucket.org/rgl/make_dmg/downloads/background.png
./make_dmg \
    -image background.png \
    -file 144,144 ../minimal-cocoa-app.app \
    -symlink 416,144 /Applications \
    -convert UDBZ \
    ../minimal-cocoa-app.dmg
'''))
project.publishersList.add(
    new ArtifactArchiver('*.tgz,*.dmg'))

Jenkins.instance.add(project, project.name)
EOF


#
# show install summary.

systemctl status jenkins
jcli version
jcli list-plugins | sort
jgroovy = <<'EOF'
import hudson.model.AbstractItem
import hudson.model.User
import jenkins.model.Jenkins

Jenkins.instance.nodes.sort { it.name }.each {
    name = it.name
    println sprintf("jenkins %s node", name)
    it.assignedLabels.sort().each { println sprintf("jenkins %s node label: %s", name, it) }
}
println "jenkins master node"
Jenkins.instance.assignedLabels.sort().each { println "jenkins master node label: " + it }
User.all.sort { it.id }.each { println sprintf("jenkins user: %s (%s)", it.id, it.fullName) }
Jenkins.instance.getAllItems(AbstractItem.class).sort { it.fullName }.each {
    println sprintf("jenkins job: %s (%s)", it.fullName, it.class)
}
EOF
echo "jenkins is installed at https://$domain"
echo "the admin password is $(cat /var/lib/jenkins/secrets/initialAdminPassword)"
echo "you can also use the vagrant user with the vagrant password"
