for i in $(cat plugin-refs.json | jq keys[] -r); do ref=$(curl https://api.github.com/repos/ManageIQ/$i/git/refs/heads/master | jq .object.sha -r); echo \"$i\": \"$ref\", >> refs; done
