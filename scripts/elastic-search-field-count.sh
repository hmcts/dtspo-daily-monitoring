#!/bin/bash

set -x

#Configuring the script
ELASTICSEARCH_HOST="10.96.85.7:9200"
OUTPUT=""

# Get the list of all index names
INDEX_LIST=$(curl -sv -XGET "$ELASTICSEARCH_HOST/_cat/indices?h=index")

#Read each index from the file
while IFS= read -r index_name; do
    if [[ -n "$index_name" ]]; then
        #Get the field count for the index
        field_count=$(curl -sv -XGET "$ELASTICSEARCH_HOST/$index_name/_mapping?pretty" | grep type | wc -l)
        index_count=$(curl -sv -XGET "$ELASTICSEARCH_HOST/_cat/indices" | awk '{print $3, $7}' | grep $index_name)
        
        # Append the result to the output variable
        if [[ $field_count -ge 7500 ]]; then
        OUTPUT+="$index_count:  Field Count - $field_count"$'\n'
        fi
    fi

done <<< "$INDEX_LIST"

echo "$OUTPUT"

echo "Saving to file" $OUTPUT > elastic-field-count.txt