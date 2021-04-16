#!/bin/bash -xe

# Allow user supplied pre userdata code
exec > >(tee /var/log/user-data.log|logger -t user-data ) 2>&1
PV_NAME=$(pvdisplay -S vg_name=vol_var -c | awk -F':' '{print $1}')
pvresize $PV_NAME &&\
lvextend -rl +100%FREE /dev/vol_var/lv_var
# SSH is only authorized from 10.254.X.X/X, we can't do this in AMI's build because it breaks Packer's connection
sed -i -e 's/^ALL:.*$/ALL: 10.254.13.0\/24/' /etc/hosts.allow
systemctl restart ssh
#!/bin/bash -x

CODENAME=$(lsb_release -cs)
RELEASE=$(lsb_release -rs)
DOMAIN=$(awk '/^search/ {print $2}' /etc/resolv.conf)
BASENAME="ndev-server"
INSTANCEID=$(ec2metadata --instance-id)
INSTANCEIDHASH=$(md5sum <<<$INSTANCEID | awk '{print $1}')
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}')

function configure-puppet() {
	echo "Configure puppet"
	cat >>/etc/puppet/puppet.conf <<-EOF
		[main]
		  vardir = /var/lib/puppet
		  ssldir = /var/lib/puppet/ssl
		[agent]
		  classfile = $statedir/classes.txt
		  localconfig = $vardir/localconfig
		  default_schedules = false
		  report            = true
		  pluginsync        = true
		  masterport        = 8140
		  environment       = development
		  certname          = $NEW_HOSTNAME.$DOMAIN
		  server            = puppet.$DOMAIN
		  listen            = false
		  splay             = false
		  splaylimit        = 1800
		  runinterval       = 900
		  noop              = false
		  configtimeout     = 120
		  usecacheonfailure = true
	EOF
	sed -i 's/\[main\]/\[main\]\npluginsync=true/' /etc/puppet/puppet.conf
}

function start-puppet() {
	systemctl stop puppet
	systemctl start puppet
}

function install-package() {
	local package_status=$(dpkg -l | grep $1 -c)

	if [ $package_status -eq 0 ]; then
		DEBIAN_FRONTEND=noninteractive apt-get install $1 -y
	fi
}

function get-tag-name() {
	local instance_id=$(ec2metadata --instance-id)

	# Get name in the tag hostname-prefix and cut by . and keep 1st part
	# ex: nodes.k8s.cloud.coveo.com --> nodes
	local name=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCEID" "Name=key,Values=hostname-prefix" --region=$REGION --output=text | cut -f5 | cut -d"." -f1)

	if [ -z $name ]; then
		echo "$BASENAME"
	else
		echo "$name"
	fi
}

function set-hostname() {
	local base_hostname=$(get-tag-name)
	# Build the hostname with the first digit of base (limited to 11 characters) and complete with last digit of instance id (minimum 4 chars)
	# This is due to the limit of 15 chars when joining the AD.
	LENGHT=4
	BASELENGHT=${#base_hostname}
	[ $BASELENGHT -lt 11 ] && LENGHT=$((15 - $BASELENGHT))
	[ $BASELENGHT -ge 11 ] && BASELENGHT=11

	NEW_HOSTNAME="${base_hostname::BASELENGHT}${INSTANCEIDHASH: -LENGHT}"

	if [ ! -z $NEW_HOSTNAME ]; then

		CUR_HOSTNAME=$(cat /etc/hostname)

		# Display the current hostname
		echo "The current hostname is $CUR_HOSTNAME"

		# Change the hostname
		hostnamectl set-hostname $NEW_HOSTNAME
		hostname $NEW_HOSTNAME

		# Change hostname in /etc/hosts & /etc/hostname
		sudo sed -i "s/$CUR_HOSTNAME/$NEW_HOSTNAME/g" /etc/hosts
		sudo sed -i "s/$CUR_HOSTNAME/$NEW_HOSTNAME/g" /etc/hostname

		# Display new hostname
		echo "The new hostname is $NEW_HOSTNAME"

		# Set Name on EC2
		echo "Change tag Name on AWS EC2"
		aws ec2 create-tags --resources "$INSTANCEID" --tags "Key=Name,Value=$NEW_HOSTNAME" --region=$REGION
	fi
}

# Change the hostname based on the tag
set-hostname

# Configure and start puppet
configure-puppet
start-puppet


# Bootstrap and join the cluster
/etc/eks/bootstrap.sh --b64-cluster-ca 'LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRFNU1USXdPVEl3TlRReU9Gb1hEVEk1TVRJd05qSXdOVFF5T0Zvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTndYCjdxSzFLQm4yMXN4eXFFcVVLTktKTXp0a2tGNmhneEFMUDRlUko2TGVIVjJ4cHVOVUdKcWk4S2Z5VnVKTEFCSXAKZzdlY0ZkVWVqL21oK2t4bENKYTdqMlllUTd0bGRmcGtnd3BydlNIU1lIVG5YQ0tKZ2ZCbWNySWRhcGhKU3BrSAovVGNrM1JOTHg3MGJFcTVXU004blJ0Ly9HeFNQMnJ1cXFpZ0xSZWFvWXpQWHpGTHpIQWxITmUrWUF2SVorQXhRClVtL3Z2YTZaekRTMHJWRlJ4SDJrUEtkRFNoNzdZRmhzYm5rcUtDM0FvSC9ub0lweGkrQjlUYndhbmp1cU9XUVcKdTIzNGtaUVd4THp6MTNJWlZTWGllRmlNMnArTUhDcElxdUZ0L2xnOGNaMkRtL1c3eG5tTW1GQTJBblloYURkZAptaVBxeFl4K1FvT3JEWHJIQXI4Q0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFNazZXN29kdVdtRFpxeXhhRHlVcmZ4QWJIUDUKWkhSdDU4TU05OGcxd241R082dmtkWlpQeHZQQnpWNzlhRXdZdElnTlNXNTRFWnZvYmE0eHEwU0ZpL2h1Nnd6UgpkdVlXUTVnR2ozcU1lYlo4QjBLclNoR2dHekdMWG5qRUNkdEgwZEo4WXh4U3ZuRmU5NFRQNzF3Y3FlN1ZRbXJ5CmF2TnhIUFJHWE84M2JEVElPbXFYN2VsMVowRVBoOXhkODRmY0MzK3I4SE14elEvNUJWUVBzaDBmcThkYWcwMmUKY0FYRnA3TnlvOXdMczJPSkpvV1ptK1JKNXNmVm5UR1h0ZUkrNDYyYm9rN0FQVTREUnFhOUhsWi9hcjJsc011VQp1ZW1KbnQrbGJ1aGNhenU4Z1habzE0SDloMjNiTGFhSlNRdFlkenRKT200RmVqRm53VGJlWkdURDlLcz0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=' --apiserver-endpoint 'https://C672728D6EA6CAFA1397A6016FD738E7.gr7.us-east-1.eks.amazonaws.com'  --kubelet-extra-args "--node-labels=dedicated=node-dpm,intent=dpm,lifecycle=ec2 --register-with-taints=dedicated=node-dpm:NoSchedule " 'dev-infra-us-east-1'

# Allow user supplied userdata code
