CXX?= c++
CC?= cc
CFLAGS += -O2 -fPIC -Wall
CXXFLAGS += -O2 -fPIC -Wall -std=c++17
PERLINC!= perl -MConfig -e 'print "-I$$Config{archlib}/CORE $$Config{ccflags}"'
TYPEMAP!= perl -MConfig -e 'print "$$Config{privlib}/ExtUtils/typemap"'
GRPC_CFLAGS!= pkg-config --cflags protobuf grpc++
GRPC_LIBS!= pkg-config --libs protobuf grpc++
PROTO= ../../proto/spacex_device.proto
GEN= gen

all: ../../blib/auto/SLMON/Dish/Dish.so

${GEN}/spacex_device.pb.cc ${GEN}/spacex_device.grpc.pb.cc: ${PROTO}
	mkdir -p ${GEN}
	protoc -I ../../proto --cpp_out=${GEN} \
	    --grpc_out=${GEN} --plugin=protoc-gen-grpc=/usr/local/bin/grpc_cpp_plugin \
	    spacex_device.proto

Dish.c: Dish.xs dishbridge.h
	xsubpp -typemap ${TYPEMAP} Dish.xs > Dish.c.tmp && mv Dish.c.tmp Dish.c

Dish.o: Dish.c
	${CC} ${CFLAGS} ${PERLINC} -c Dish.c

dishbridge.o: dishbridge.cc dishbridge.h ${GEN}/spacex_device.pb.cc ${GEN}/spacex_device.grpc.pb.cc
	${CXX} ${CXXFLAGS} ${GRPC_CFLAGS} -I${GEN} -c dishbridge.cc

spacex_device.pb.o: ${GEN}/spacex_device.pb.cc
	${CXX} ${CXXFLAGS} ${GRPC_CFLAGS} -I${GEN} -c ${GEN}/spacex_device.pb.cc -o $@

spacex_device.grpc.pb.o: ${GEN}/spacex_device.grpc.pb.cc
	${CXX} ${CXXFLAGS} ${GRPC_CFLAGS} -I${GEN} -c ${GEN}/spacex_device.grpc.pb.cc -o $@

../../blib/auto/SLMON/Dish/Dish.so: Dish.o dishbridge.o spacex_device.pb.o spacex_device.grpc.pb.o
	mkdir -p ../../blib/auto/SLMON/Dish
	${CXX} -shared -fPIC -o $@ Dish.o dishbridge.o spacex_device.pb.o \
	    spacex_device.grpc.pb.o ${GRPC_LIBS}

clean:
	rm -rf ${GEN} Dish.c *.o ../../blib/auto/SLMON/Dish/Dish.so

.PHONY: all clean
