# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Deliberately held back; do not bump without reworking the seed data and the
# ratings client. MongoDB 8.0.24 and later refuse to start on Linux kernel 6.19+
# (https://jira.mongodb.org/browse/SERVER-121912). The incompatibility affects
# the whole 8.0 line -- 8.0.8 simply starts anyway rather than failing loudly --
# so there is no patch release we can move to. Escaping it means 8.2/8.3, which
# additionally requires fixing mongoimport's rejection of ratings_data.json and
# replacing the mongodb 3.x driver in samples/bookinfo/src/ratings, since that
# driver cannot connect to those servers.
FROM mongo:8.0.8
WORKDIR /app/data/
COPY ratings_data.json /app/data/
COPY script.sh /docker-entrypoint-initdb.d/
RUN chmod +x /docker-entrypoint-initdb.d/script.sh
