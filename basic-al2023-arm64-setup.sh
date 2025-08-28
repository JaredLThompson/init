#! /bin/bash


sudo yum -y update
sudo yum -y install zsh git vim util-linux-user

initArch() {
  ARCH=$(uname -m)
  case $ARCH in
    armv5*) ARCH="armv5";;
    armv6*) ARCH="armv6";;
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
  esac
}

initArch


# install kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.28.1/2023-09-14/bin/linux/$ARCH/kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$PATH:$HOME/bin
echo 'export PATH=$PATH:$HOME/bin' >> ~/.bashrc
echo 'export PATH=$PATH:$HOME/bin' >> ~/.zshrc

# install terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform

# Change shell to zsh
touch ~/.zshrc
sudo chsh -s $(which zsh) ec2-user

#installing Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

# Installing eksctl
# for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo mv /tmp/eksctl /usr/local/bin

# Install ohmyz.sh
rm install.sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Updating Plugins
sed -i 's/plugins=(git)/plugins=(git aws kubectl)/g' ~/.zshrc

#updating theme
sed -i 's/robbyrussell/pygmalion/g' ~/.zshrc
echo 'export PATH=$PATH:$HOME/bin' >> ~/.zshrc
echo 'alias tf="terraform"' >> ~/.zshrc
echo 'alias k="kubectl"' >> ~/.zshrc

# Add tagging from EC2 Instance Metadata to the prompt
cat << 'EOF' >> ~/.zshrc

# AWS Instance Metadata Tag Function
function get_instance_tag() {
    # Cache file location
    TAG_KEY="console-name"
    CACHE_FILE="/tmp/instance_tag_cache"
    CURRENT_TIME=$(date +%s)

    # Check if cache exists and is less than 1 hour old
    if [ -f "$CACHE_FILE" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            FILE_TIME=$(stat -f %m "$CACHE_FILE")
        else
            # Linux
            FILE_TIME=$(stat -c %Y "$CACHE_FILE")
        fi

        if (( CURRENT_TIME - FILE_TIME < 3600 )); then
            cat "$CACHE_FILE"
            return
        fi
    fi

    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)

    # Use token to get the tag value (replace TAG_KEY with your desired tag name)
    TAG_VALUE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/tags/instance/$TAG_KEY 2>/dev/null)

    echo "$TAG_VALUE" > "$CACHE_FILE"
    echo "$TAG_VALUE"
}

# Update PROMPT to include instance tag
PROMPT='%{$fg[green]%}[$(get_instance_tag)]%{$reset_color%} '$PROMPT
EOF

echo "Function has been added to ~/.zshrc"


#Change to zsh
zsh
source ~/.zshrc
