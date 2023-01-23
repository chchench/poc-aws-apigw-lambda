import boto3
import json

# define the DynamoDB table that Lambda will connect to

client = boto3.client('dynamodb')
table_name = "RequestRecords"

def handler(event, context):

    op = event['operation']

    print('operation requested: ' + op)

    if op != 'read':
        return {
            'statusCode': 400,
            'body': 'Invalid operation requested'
        }

    id = event['id']

    print('item id requested: ' + id)


    data = client.query(
        TableName=table_name,
        KeyConditionExpression='#name = :value',
        ExpressionAttributeValues={
            ':value': {'S': id}
        },
        ExpressionAttributeNames={
            '#name': 'Id'
        }
    )

    lst = []
    for i in data['Items']:
        entry = json.loads(i['JSON']['S'])
        val = entry['key']
        lst.append(val)
        print(val)

    response_payload = json.dumps(lst)
    
    response = {
        'statusCode': 200,
        'body': response_payload,
        'headers': {
            'Content-Type': 'application/json'
        },
    }
    
    return response

# {
#   "operation": "read",
#   "id": "1234567"
# }

