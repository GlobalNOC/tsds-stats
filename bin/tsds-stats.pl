#!/usr/bin/perl
use strict;
use warnings;
use MongoDB;
use Data::Dumper;
use JSON;
use feature 'say';
use GRNOC::Log;
use GRNOC::WebService::Client;

#initialization
my $dir = "/etc/grnoc/tsds/";
my $config_file = $dir."config.xml";
my $logging_file = $dir."logging.conf";
my $config = GRNOC::Config->new( config_file => $config_file,force_array => 0 );
GRNOC::Log->new(config => $logging_file);
log_debug("TSDS Job started");

# Just a MongoDB Connect
sub connect {
	my $client;
	eval {
		$client = MongoDB::MongoClient->new(
	            host     => $config->get('/config/mongo/@host'),
		    port     => $config->get('/config/mongo/@port'),
		    username => $config->get('/config/mongo/root')->{'user'},
		    password => $config->get('/config/mongo/root')->{'password'},
		    db_name  => $config->get('/config/mongo/root')->{'db'}
		);
	};
	if($@) {
		log_error('Unable to connect to mongodb');
		exit();
	}	
	log_debug("Connected to Mongodb");
        return $client;
}

# Client Utilization Element
sub get_active_measurements {
	my ($db, $network, $time,$count) = @_;
	my %element;
	$element{interval} = 300;
	$element{meta} = { "measurement_type" => $db, "network" => $network};
	$element{time} = $time;
	$element{type} = "active_measurements";
	$element{values} = {"numactive" => $count};
	return %element;		
}

# Get Collection indexes seperate
sub get_collection_indexes {
        my $out = $_[0];
        my $time = $_[1];
        my $db = $_[2];
        my $collection = $_[3];
	my @elements = ();
	my %index_sizes = %{ $out->{indexSizes} };	
	foreach my $key (keys %index_sizes) {			
		my %element;
		$element{type} = "collection_indexes";
	        $element{interval} = 300;
        	$element{meta} = { "collection_name" => $collection, "measurement_type"=> $db};
	        $element{time} = $time;	
		$element{meta} = { "collection_name" => $collection, "measurement_type"=> $db, "index_name" => $key};
		$element{values} = {"size" => $index_sizes{$key}};
		push(@elements,\%element );

	}
	return @elements;
		
}

# Get Collection stats data
sub get_collection_stats {
	my $out = $_[0];
	my $time = $_[1];
	my $db = $_[2];
	my $collection = $_[3];
	my %element;
        $element{type} = "measurement_collection_stats";
        $element{interval} = $config->get('/config/tsds/@interval');
        $element{meta} = { "collection_name" => $collection, "measurement_type"=> $db};
        $element{time} = $time;
        $element{values} = {"avgObjSize" => $out->{avgObjSize}, "count" => $out->{count} , "storageSize" => $out->{storageSize}, "totalIndexSize" => $out->{totalIndexSize}};
        return %element;

}

# Push Json data to TSDS
sub push_data {
	my $json_data = $_[0];	
	#log_debug("Data: ".$json_data);	
	eval {
        	my $http = GRNOC::WebService::Client->new(
        		url => $config->get('/config/tsds/@url'),
		        uid => $config->get('/config/tsds/auth')->{'user'},
		        passwd => $config->get('/config/tsds/auth')->{'password'},
		        usePost => 1
		);
		my $res = $http->add_data(data=>$json_data);
		
		log_debug("Response: ".$res->{'results'});
	};
	if($@) {
		log_error("Cannot push data to TSDS");
		exit();
	}
	#print "Result = " . Dumper($res);
}


# Start
my $client = &connect;
my @db_list = $client->database_names;
my @active_measurements_elements = ();
my @collection_stats_elements = ();
my @collection_indexes_elements = ();
my $epoc = time();

eval {

#Iterating DB in MongoDB
foreach my $n (0 .. $#db_list) {
	my $db = $client->get_database($db_list[$n]);

	my $measurements = $db->get_collection('measurements');
	if($db_list[$n] eq "interface") {
		my $out = $measurements->aggregate(
			[
				{'$match' => {end => undef }},
		       		{'$group' => {_id => '$network', count => {'$sum' => 1}}}
    			]
		);
		for my $element (@$out) {			
			my $network = $element->{_id};
			if(!defined $network || $network eq '' ) {
				$network = 'None';
			}
			my %active_measurements_element = get_active_measurements($db_list[$n],$network,$epoc,$element->{count});
			push( @active_measurements_elements, \%active_measurements_element );
		}
	} else {
		my $count = $measurements->count({end => undef});
		my %active_measurements_element = get_active_measurements($db_list[$n],'all',$epoc,$count);
		push( @active_measurements_elements, \%active_measurements_element );
	}	
	
	#Collection Index information
	my @collections = $db->collection_names;
	if( grep { $_ eq 'measurements'} @collections ) {
		for my $collection(@collections) {
			if($collection =~ m/^data/i || $collection eq 'measurements') {
				my $collection_obj = $db->get_collection($collection);
				my $out = $db->run_command({
					'collStats' => $collection
				});
				my %collection_stats_element = get_collection_stats($out,$epoc,$db_list[$n],$collection);
				push( @collection_stats_elements, \%collection_stats_element);
				
				my @collection_indexes_elements_temp = get_collection_indexes($out,$epoc,$db_list[$n],$collection);
				push( @collection_indexes_elements,@collection_indexes_elements_temp );
			}
		}
	}
}

#Pushing the JSON String to TSDS
push_data(encode_json(\@active_measurements_elements));
push_data(encode_json(\@collection_stats_elements));
push_data(encode_json(\@collection_indexes_elements));
my $interval = (time() - $epoc);
log_info("TSDS Job completed in ". $interval );

};

if($@) {
	log_error("Unexpected Error");
	exit();
}






