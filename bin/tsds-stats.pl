#!/usr/bin/perl
use strict;
use warnings;
use MongoDB;
use Data::Dumper;
use JSON;
use feature 'say';
use GRNOC::Log;
use GRNOC::WebService::Client;
use GRNOC::Monitoring::Service::Status qw(write_service_status);
use Getopt::Long;

#initialization
my $config = "/etc/grnoc/tsds-stats/config.xml";
my $logging = "/etc/grnoc/tsds-stats/logging.conf";
my $status = "/var/lib/grnoc/tsds-stats/";

#CMD args
GetOptions( 'config=s' => \$config,'logging=s' => \$logging, 'status=s' => \$status);

my $conf = GRNOC::Config->new( config_file => $config,force_array => 0 );
GRNOC::Log->new(config => $logging);
log_debug("TSDS Job started");
log_info("Using --config $config --logging $logging --status $status");

# Just a MongoDB Connect
sub connect {
	my $client;
	eval {
		$client = MongoDB::MongoClient->new(
	            host     => $conf->get('/config/mongo/@host'),
		    port     => $conf->get('/config/mongo/@port'),
		    username => $conf->get('/config/mongo/root')->{'user'},
		    password => $conf->get('/config/mongo/root')->{'password'},
		    db_name  => $conf->get('/config/mongo/root')->{'db'}
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
        $element{interval} = $conf->get('/config/tsds/@interval');
        $element{meta} = { "collection_name" => $collection, "measurement_type"=> $db};
        $element{time} = $time;
        $element{values} = {"avgObjSize" => $out->{avgObjSize}, "count" => $out->{count} , "storageSize" => $out->{storageSize}, "totalIndexSize" => $out->{totalIndexSize}};

	if (exists $out->{'shards'}){
	    foreach my $shard (sort keys %{$out->{'shards'}}){
		my $block_manager = $out->{'shards'}{$shard}{'wiredTiger'}{'block-manager'};
		my $size_free  = $block_manager->{'file bytes available for reuse'};
		my $size_total = $block_manager->{'file size in bytes'};
		$element{'values'}{"shard_size_free"} += $size_free;
		$element{'values'}{"shard_size_total"} += $size_total;
	    }
	}

        return %element;

}

# Push Json data to TSDS
sub push_data {
	my $json_data = $_[0];	
	#log_debug($json_data);	
	eval {
        	my $http = GRNOC::WebService::Client->new(
        		url => $conf->get('/config/tsds/@url'),
		        uid => $conf->get('/config/tsds/auth')->{'user'},
		        passwd => $conf->get('/config/tsds/auth')->{'password'},
		        usePost => 1
		);
		my $res = $http->add_data(data=>$json_data);
		
		log_debug("Response: ".$res->{'results'});
	};
	if($@) {
		log_error("Cannot push data to TSDS");
		exit();
	}
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
 
        next if (grep { $_ eq $db_list[$n] } ('admin', 'config', 'local'));
    

	my $db = $client->get_database($db_list[$n]);

	my @collections = $db->collection_names;
	if( grep { $_ eq 'measurements'} @collections ) {
		my $measurements = $db->get_collection('measurements');
        	if($db_list[$n] eq "interface") {
                	my @out = $measurements->aggregate(
	                        [
        	                        {'$match' => {end => undef }},
                	                {'$group' => {_id => '$network', count => {'$sum' => 1}}}
                        	]
	                )->all();
        	        for my $element (@out) {
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
	log_error("Unexpected Error: $@");
	exit();
}

my $res = write_service_status( path => $status, error => 0, error_txt => "");




