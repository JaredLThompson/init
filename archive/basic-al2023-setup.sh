#! /bin/bash


sudo yum -y update

sudo yum -y install zsh git vim util-linux-user

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# install kubectl
curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.23.7/2022-06-29/bin/linux/amd64/kubectl
chmod +x ./kubectl
mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$PATH:$HOME/bin
echo 'export PATH=$PATH:$HOME/bin' >> ~/.bashrc
echo 'export PATH=$PATH:$HOME/bin' >> ~/.zshrc

# install terraform
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum -y install terraform

# Change shell to zsh
# chsh -s $(which zsh)
# sudo sed -i 's/home\/ec2-user:\/bin\/bash/home\/ec2-user:\/usr\/bin\/zsh/g' /etc/passwd
touch ~/.zshrc
sudo chsh -s $(which zsh) ec2-user
source ~/.zshrc

#installing Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

# Installing eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Installing ohmyz.sh
sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Keep ssh sessions alive
echo ServerAliveInterval 50 > ~/.ssh/config
chmod 400 ~/.ssh/config

# Updating Plugins
sed -i 's/plugins=(git)/plugins=(git aws kubectl)/g' ~/.zshrc

#updating theme
sed -i 's/robbyrussell/pygmalion/g' ~/.zshrc
echo 'export PATH=$PATH:$HOME/bin' >> ~/.zshrc
echo 'alias tf="terraform"' >> ~/.zshrc
echo 'alias k="kubectl"' >> ~/.zshrc

source ~/.zshrc
