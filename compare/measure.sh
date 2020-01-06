#!/bin/bash
COMPILE_TIMES=1
STARTUP_TIMES=1

function check(){
    compileTime "$1" "$2" "$3" "$4"
    startup     "$2"
}

function compileTime(){
    for (( i=0; i<COMPILE_TIMES; i++))
    do
        #make a clean first as we want to measure a full rebuild
        clean "$1" "$3"

	#Build the application and store the time needed to results
        startNS=$(date +"%s%N")
	compile "$1" "$3" "$4"
	buildImage "$2"
        endNS=$(date +"%s%N")
        compiletime=$(echo "scale=2;($endNS-$startNS)/1000000000" | bc)
	echo "$2, Compile time, $compiletime" >> results.csv
    done
}

function clean() {
    pushd ../$1
    if [ "$2" == "mvn" ]
    then
        ./mvnw clean
    else
        ./gradlew clean
    fi
    if [ $? -ne 0 ]
    then
        popd
        fail "Could not clean folder $1"
    fi
    popd
}

function compile(){
    pushd ../$1
    if [ "$2" == "mvn" ]
    then
        ./mvnw package $3
    else
        ./gradlew assemble
    fi

    if [ $? -ne 0 ]
    then
        popd
        fail "Could not build folder $1"
    fi
    popd
}
 
function buildImage(){
    docker-compose build $1
    if [ $? -ne 0 ]
    then
        fail "Could not build image $1"
    fi
}

function startup(){
    for (( i=0; i<STARTUP_TIMES; i++))
    do
        #Recreate the container to always have a startup from null
        disposeContainer "$1"

        #Start the container and measure how long it takes untill we get a valid result
        startNS=$(date +"%s%N")
        startContainer "$1"
        endNS=$(date +"%s%N")
        startuptime=$(echo "scale=2;($endNS-$startNS)/1000000000" | bc)
	echo "$1, Startup time, $startuptime" >> results.csv

        #Measure memory
        memory=$(docker stats --format "{{.MemUsage}}" --no-stream "compare_$1_1")
	echo "$1, Memory Usage (Startup), $memory" >> results.csv

        #Make sure container runs normally
        checkContainer "$1"
    done

    #Stop container again
    disposeContainer "$1"
}

function disposeContainer() {
    docker-compose stop $1
    docker-compose rm -f $1
}

function startContainer() {
    docker-compose up -d $1
    cameUp=0
    for (( i=0; i<100; i++))
    do
        sleep 0.3
        curl -s http://localhost:8080/issue/550e8400-e29b-11d4-a716-446655440000/ | grep "This is a test" > /dev/null
        if [ $? -eq 0 ]
        then
            return;
        fi;
    done
    curl http://localhost:8080/issue/550e8400-e29b-11d4-a716-446655440000/ -v
    fail "Container could not start"
}

function checkContainer() {
    curl -s http://localhost:8080/issue/ | grep "This is a test" > /dev/null
    if [ $? -ne 0 ]
    then
        curl http://localhost:8080/issue/ -v
        fail "Failed GET ALL for $1"
    fi;

    #Create a new entry
    curl -X POST http://localhost:8080/issue/ \
        -d '{"id":"550e8400-e29b-11d4-a728-446655440000","name":"Test 123", "description":"Test 28"}' \
        -H "Content-Type: application/json" 
    curl -s http://localhost:8080/issue/ | grep "Test 28" > /dev/null
    if [ $? -ne 0 ]
    then
        curl http://localhost:8080/issue/ -v
        fail "Failed CREATE for $1"
    fi;

    #Patch new entry
    curl -X PATCH http://localhost:8080/issue/550e8400-e29b-11d4-a728-446655440000/ \
        -d '{"description":"Test NEW"}' \
       	-H "Content-Type: application/json" 
    curl -s http://localhost:8080/issue/ | grep "Test NEW" > /dev/null
    if [ $? -ne 0 ]
    then
        curl http://localhost:8080/issue/ -v
        fail "Failed PATCH for $1"
    fi;

    #Delete new entry
    curl -X DELETE http://localhost:8080/issue/550e8400-e29b-11d4-a728-446655440000/
    curl -s http://localhost:8080/issue/ | grep "Test NEW" > /dev/null
    if [ $? -eq 0 ]
    then
        curl http://localhost:8080/issue/ -v
        fail "Failed DELETE for $1"
    fi;
}

function fail() {
    echo "$1"  1>&2;
    exit -1
}

function prepare () {
    rm -f results.csv
    docker-compose stop
    docker-compose rm -f postgres
    docker-compose build postgres
    docker-compose up -d postgres
}

prepare
check "helidon-mp"     "helidon-mp"           "mvn"
check "spring"         "spring"               "mvn"
check "quarkus"        "quarkus"              "mvn"
check "micronaut-jdbc" "micronaut-jdbc"       "gradle"
check "micronaut-jpa"  "micronaut-jpa"        "gradle"
check "quarkus"        "quarkus-graal"        "mvn"     "-Pnative -Dquarkus.native.container-build=true"
check "micronaut-jdbc" "micronaut-jdbc-graal" "gradle"
check "micronaut-jpa"  "micronaut-jpa-graal"  "gradle"

cat results.csv;
