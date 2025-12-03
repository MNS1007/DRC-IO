# Installing AWS CLI

## Current Status

AWS CLI is already installed on this system:
- **Version**: aws-cli/2.31.9
- **Location**: `/opt/homebrew/bin/aws`

## Installation Methods for macOS

### Method 1: Using Homebrew (Recommended)

If you have Homebrew installed:

```bash
brew install awscli
```

To upgrade an existing installation:
```bash
brew upgrade awscli
```

### Method 2: Using the Official AWS Installer

1. Download the macOS installer:
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
```

2. Install it:
```bash
sudo installer -pkg AWSCLIV2.pkg -target /
```

3. Verify installation:
```bash
aws --version
```

### Method 3: Using pip (Python)

If you have Python 3.7+ installed:

```bash
pip3 install awscli --upgrade --user
```

Add to PATH (if needed):
```bash
echo 'export PATH=~/.local/bin:$PATH' >> ~/.zshrc
source ~/.zshrc
```

## Installation for Other Platforms

### Linux

**Using package manager (Ubuntu/Debian):**
```bash
sudo apt-get update
sudo apt-get install awscli
```

**Using the official installer:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### Windows

1. Download the MSI installer from: https://awscli.amazonaws.com/AWSCLIV2.msi
2. Run the installer and follow the prompts
3. Open a new Command Prompt and verify:
```cmd
aws --version
```

## Configuration

After installation, configure AWS CLI with your credentials:

```bash
aws configure
```

You'll need to provide:
- **AWS Access Key ID**: Your AWS access key
- **AWS Secret Access Key**: Your AWS secret key
- **Default region name**: e.g., `us-west-2`
- **Default output format**: `json` (recommended)

### Using AWS Profiles

For multiple AWS accounts:

```bash
aws configure --profile myprofile
```

Use a profile:
```bash
export AWS_PROFILE=myprofile
# or
aws s3 ls --profile myprofile
```

### Using IAM Roles (for EC2/ECS/EKS)

If running on AWS infrastructure, you can use IAM roles instead of credentials:

```bash
# No configuration needed - role is automatically used
aws sts get-caller-identity
```

## Verification

Test your installation and configuration:

```bash
# Check version
aws --version

# Verify credentials (shows your AWS account ID)
aws sts get-caller-identity

# List S3 buckets (requires permissions)
aws s3 ls

# Test EKS access (if you have a cluster)
aws eks list-clusters --region us-west-2
```

## Troubleshooting

### Command not found

If `aws` command is not found after installation:

1. Check if it's in your PATH:
```bash
which aws
```

2. Add to PATH manually:
```bash
# For Homebrew installations
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### Permission denied

If you get permission errors:
```bash
chmod +x $(which aws)
```

### Credentials not working

- Verify your AWS credentials are correct
- Check IAM permissions
- Ensure your AWS account is active
- Try regenerating access keys in IAM Console

### Region issues

Set default region:
```bash
aws configure set region us-west-2
```

Or use environment variable:
```bash
export AWS_DEFAULT_REGION=us-west-2
```

## Updating AWS CLI

**Homebrew:**
```bash
brew upgrade awscli
```

**Official installer (macOS/Linux):**
```bash
# Download and install latest version
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

**pip:**
```bash
pip3 install --upgrade --user awscli
```

## Additional Tools

### AWS CLI Session Manager Plugin

For secure access to EC2 instances without SSH keys:

```bash
# macOS
brew install --cask session-manager-plugin

# Or download manually
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "sessionmanager-bundle.zip"
unzip sessionmanager-bundle.zip
sudo ./sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
```

### eksctl (for EKS cluster management)

```bash
# macOS
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl

# Or download binary
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Darwin_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```

## Next Steps for DRC I/O Project

Once AWS CLI is installed and configured:

1. **Verify access:**
```bash
aws sts get-caller-identity
```

2. **Set default region:**
```bash
aws configure set region us-west-2  # or your preferred region
```

3. **Test EKS access (if cluster exists):**
```bash
aws eks list-clusters --region us-west-2
```

4. **Run the deployment script:**
```bash
cd drc_io_agent
./test-aws.sh
```

## Resources

- **AWS CLI Documentation**: https://docs.aws.amazon.com/cli/
- **AWS CLI Command Reference**: https://awscli.amazonaws.com/v2/documentation/api/latest/index.html
- **AWS CLI GitHub**: https://github.com/aws/aws-cli

