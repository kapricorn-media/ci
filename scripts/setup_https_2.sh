sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot certonly --standalone --agree-tos --email kapricornmedia@gmail.com -d ci-1.kapricornmedia.com