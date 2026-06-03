#!/bin/bash
# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Make the repository directory safe for git
git config --global --add safe.directory /litert_build
git config --global --add safe.directory /litert_build/third_party/tensorflow

/litert_build/configure --workspace=/litert_build

echo "Configuration complete. .litert_configure.bazelrc has been generated at /litert_build/.litert_configure.bazelrc"

# Execute the command passed to the entrypoint
exec "$@"
