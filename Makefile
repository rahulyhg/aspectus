# deployment depends on having already run `aws configure`

all: deployment_test form.html # TODO: delete line when d'test depends on f'html

deployment_test: deploy deployment.url web_response.ics.masked.expected
	wget $(shell cat deployment.url)?place=flint%20hill%20va\&lookaheaddays=1\&startdate=2017/01/01 \
	    --output-document=web_response.ics
	sed -e 's/DATE-TIME:.*/DATE-TIME:.../' \
	    -e 's/Sextant/*/' \
	    -e 's/Trine/*/' \
	    web_response.ics > web_response.ics.masked
	diff -b web_response.ics.masked \
	     web_response.ics.masked.expected
	echo Deployment test\(s\) passed. $(TIMESTAMP_FILE_CONTENTS) \
	    > deployment_test

form.html: form.html_blank_action deployment.url
	sed -e 's!form action=\"\"!form action=\"$(shell cat deployment.url)\"!' \
	    form.html_blank_action > form.html

AWS_NAME=aspectus
AWS_DESCRIPTION="Chart upcoming astrological events"

deployment.url: configure_aws_environment aws_apigateway_deployment_stage
	echo https://$(shell cat aws_apigateway_api_id).execute-api.$(shell aws \
	    configure get region).amazonaws.com/$(shell cat aws_apigateway_deployment_stage_name)/$(AWS_NAME)\
	    >deployment.url

deploy: deployment.zip configure_aws_environment
	aws s3 cp deployment.zip s3://$(AWS_NAME)/
	aws lambda update-function-code \
	    --function-name $(AWS_NAME) \
	    --s3-bucket $(AWS_NAME) \
	    --s3-key deployment.zip \
	    > deploy
	echo Deployment successful. $(TIMESTAMP_FILE_CONTENTS)>deploy

unit_test: *.py tests/*.py
	python -m unittest discover -s tests --verbose
	@echo Unit test\(s\) passed. $(TIMESTAMP_FILE_CONTENTS) > unit_test

pylint: unit_test
	pylint --rcfile .pylintrc *.py tests/*.py
	echo Pylint checks successful. $(TIMESTAMP_FILE_CONTENTS) > pylint

deployment.zip: pylint deployment_dependency_libraries
	rm -rf deployment
	mkdir deployment
	cp *.py deployment
	cp -R deployment_dependency_libraries/* deployment
	cd deployment ; \
	    zip -qr ../deployment.zip *
	rm -rf deployment

configure_aws_environment: aws_lambda_arn \
                           aws_apigateway_api_id \
                           aws_apigateway_resource_id \
                           aws_apigateway_method \
                           aws_apigateway_api_arn
	aws apigateway put-integration \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --resource-id $(shell cat aws_apigateway_resource_id) \
	    --http-method $(shell cat aws_apigateway_method) \
	    --type AWS_PROXY \
	    --integration-http-method POST \
	    --uri arn:aws:apigateway:$(shell aws configure get \
	        region):lambda:path/2015-03-31/functions/$(shell \
	        cat aws_lambda_arn)/invocations #\
	    #--request-parameters 'method.request.queryString.place=string,method.request.queryString.lookaheaddays=string'
	aws apigateway put-method-response \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --resource-id $(shell cat aws_apigateway_resource_id) \
	    --http-method $(shell cat aws_apigateway_method) \
	    --status-code 200 \
	    --response-models "{}"
	aws apigateway put-integration-response \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --resource-id $(shell cat aws_apigateway_resource_id) \
	    --http-method $(shell cat aws_apigateway_method) \
	    --status-code 200 \
	    --selection-pattern ".*"
	aws lambda add-permission \
	    --function-name $(AWS_NAME) \
	    --statement-id $(AWS_NAME)-all-stages \
	    --action lambda:InvokeFunction \
	    --principal apigateway.amazonaws.com \
	    --source-arn "$(shell cat aws_apigateway_api_arn)/*/$(shell \
	        cat aws_apigateway_method)/$(AWS_NAME)"
	aws s3 mb s3://$(AWS_NAME)
	echo AWS environment configured. $(TIMESTAMP_FILE_CONTENTS) \
	    > configure_aws_environment

aws_apigateway_api_id:
	aws apigateway create-rest-api \
	    --name $(AWS_NAME) \
	    --description $(AWS_DESCRIPTION) \
	    --output text \
	    --query "id" \
	    > aws_apigateway_api_id \
	    || (rm -f aws_apigateway_api_id ; false)

aws_apigateway_resource_id: aws_apigateway_parent_resource_id
	aws apigateway create-resource \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --parent-id $(shell cat aws_apigateway_parent_resource_id) \
	    --path-part $(AWS_NAME) \
	    --query 'id' \
	    --output text \
	    > aws_apigateway_resource_id \
	    || (rm -f aws_apigateway_resource_id ; false)

aws_apigateway_parent_resource_id:
	aws apigateway get-resources \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --query "items[?path=='/'].id" \
	    --output text \
	    > aws_apigateway_parent_resource_id \
	    || (rm -f aws_apigateway_parent_resource_id ; false)

aws_apigateway_method: aws_apigateway_api_id aws_apigateway_resource_id
	aws apigateway put-method \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --resource-id $(shell cat aws_apigateway_resource_id) \
	    --http-method GET \
	    --authorization-type NONE \
	    --query 'httpMethod' \
	    --output text \
	    > aws_apigateway_method \
	    || (rm -f aws_apigateway_method ; false)

aws_apigateway_api_arn: aws_lambda_arn aws_apigateway_api_id
	sed -e 's/lambda/execute-api/' \
	    -e "s/function:$(AWS_NAME)/$(shell cat aws_apigateway_api_id)/" \
	    aws_lambda_arn > aws_apigateway_api_arn

aws_lambda_arn: aws_iam_role_arn
	zip empty.zip aws_iam_role_arn
	aws lambda create-function \
	    --function-name $(AWS_NAME) \
	    --description $(AWS_DESCRIPTION) \
	    --runtime python2.7 \
	    --role $(shell cat aws_iam_role_arn) \
	    --handler $(AWS_NAME).lambda_handler \
	    --zip-file fileb://empty.zip \
	    --query 'FunctionArn' \
	    --output text \
	    > aws_lambda_arn \
	    || (rm -f empty.zip aws_lambda_arn ; false)
	rm -f empty.zip

aws_iam_role_arn: aws_iam_assume_role_policy.json
ifeq "$(wildcard aws_iam_role_arn)" ""
	$(info file aws_iam_role_arn does not exist. creating.)
	aws iam create-role \
	    --role-name $(AWS_NAME) \
	    --assume-role-policy-document file://aws_iam_assume_role_policy.json \
	    --path /service-role/ \
	    --output text \
	    --query "Role.Arn" \
	    > aws_iam_role_arn \
	    || (rm -f aws_iam_role_arn ; false)
	aws iam attach-role-policy \
	    --role-name $(AWS_NAME) \
	    --policy-arn \
	        arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
	    || (rm aws_iam_role_arn ; false)
	sleep 10 # to let it sink in. w/out this, lambda create-function complains
else
	$(info file aws_iam_role_arn already exists. updating existing arn.)
	aws iam update-assume-role-policy \
	    --role-name $(AWS_NAME) \
	    --policy-document file://aws_iam_assume_role_policy.json
endif

aws_apigateway_deployment_stage: aws_apigateway_deployment_stage_name \
                                 aws_apigateway_api_id \
                                 aws_apigateway_api_arn \
                                 aws_apigateway_method
	aws apigateway create-deployment \
	    --rest-api-id $(shell cat aws_apigateway_api_id) \
	    --description $(AWS_DESCRIPTION) \
	    --stage-name $(shell cat aws_apigateway_deployment_stage_name)
	aws lambda add-permission \
	    --function-name $(AWS_NAME) \
	    --statement-id \
	        apigateway-$(AWS_NAME)-stage-$(shell cat aws_apigateway_deployment_stage_name) \
	    --action lambda:InvokeFunction \
	    --principal apigateway.amazonaws.com \
	    --source-arn "$(shell cat \
	        aws_apigateway_api_arn)/$(shell cat aws_apigateway_deployment_stage_name)/$(shell \
	        cat aws_apigateway_method)/$(AWS_NAME)"
	sleep 3 # let sink in. w/out this, a changed stage name will yield an HTTP 403 in the deployment test
	echo AWS API Gateway Deployment Stage created. $(TIMESTAMP_FILE_CONTENTS) \
	    >aws_apigateway_deployment_stage

deployment_dependency_libraries: requirements.txt
	$(info may fail if pip compiles binaries for non-x86_64 Linux)
	rm -rf ./deployment_dependency_libraries
	pip install \
	    --requirement requirements.txt \
	    --target ./deployment_dependency_libraries \
	    --compile

clean: clean_aws_environment
	rm -rf *.pyc \
	       web_response.ics \
	       web_response.ics.masked \
	       unit_test
	rm -rf deployment_test \
	       deploy \
	       deployment.url \
	       deployment.zip \
	       deployment_dependency_libraries \
	       form.html

clean_aws_environment:
ifneq "$(wildcard aws_apigateway_api_id)" ""
	aws apigateway delete-rest-api \
	   --rest-api-id $(shell cat aws_apigateway_api_id)
	rm -f aws_apigateway_api_id
endif
	$(info if there are multiple apigateways to delete, or if the created \
	    API ID does not get captured in the file aws_apigateway_api_id, \
	    this can take forever...)
	$(info without these crazy sleeps, we will get TooManyRequestsException)
	for i in `aws apigateway get-rest-apis \
	              --output text \
	              --query "items[?name=='$(AWS_NAME)'].id"` ; do \
	    aws apigateway delete-rest-api --rest-api-id $$i ; \
	    sleep 30 ; done
	rm -f aws_apigateway_api_arn \
	      aws_apigateway_method \
	      aws_apigateway_parent_resource_id \
	      aws_apigateway_resource_id \
	      configure_aws_environment \
	      aws_iam_role_arn \
	      aws_lambda_arn
	if aws iam list-roles | grep -q $(AWS_NAME) ; then \
	    aws iam detach-role-policy \
	        --role-name $(AWS_NAME) \
	        --policy-arn \
	            arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
	        || false ; \
	    aws iam delete-role --role-name $(AWS_NAME) || false ; fi
	if aws lambda list-functions | grep -q $(AWS_NAME) ; then \
	    aws lambda delete-function --function-name $(AWS_NAME) || false ; fi
	if aws s3 ls | grep -q $(AWS_NAME) ; then \
	    aws s3 rm --recursive s3://$(AWS_NAME)/ --include \* || false ; \
	    aws s3 rb s3://$(AWS_NAME) || false ; fi

TIMESTAMP_FILE_CONTENTS=This file is a placeholder whose only significance is \
in its timestamp. Its purpose is to indicate which Makefile targets need to \
be executed. Changing the timestamp of this file \(such as by \
updating/writing to it\) will likely break Makefile funcionality.
