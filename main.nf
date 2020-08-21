#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/hlatyping
========================================================================================
 nf-core/hlatyping Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/hlatyping
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/hlatyping --input '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input FastQ or BAM file(s). The path must be enclosed in quotes.
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated).
                                      Options: conda, docker, singularity, test, awsbatch, <institute> and more

    Main options:
      --single_end [bool]             Specifies that the input is single-end reads.
                                      Default: ${params.single_end}
      --bam [bool]                    Specifies that the input is in BAM format.
                                      Default: ${params.bam}
      --seqtype [str]                 Specifies whether the input is DNA or RNA. Options: 'dna', 'rna'
                                      Default: '${params.seqtype}'
      --solver [str]                  Specifies the integer programming solver. Options: 'glpk', 'cbc'
                                      Default: '${params.solver}'
      --enumerations [int]            Specifies the number of output solutions.
                                      Default: ${params.enumerations}

    Reference genome options:
      --base_index_path [str]         Path for the mapping reference index location.
      --base_index_name [str]         Name of the mapping reference index.

    Resource options:
      --max_memory [str]              Maximum amount of memory that can be requested for any single job (format integer.unit). 
                                      Default: '${params.max_memory}'
      --max_time [str]                Maximum amount of time that can be requested for any single job (format integer.unit).
                                      Default: '${params.max_time}'
      --max_cpus [int]                Maximum number of CPUs that can be requested for any single job. 
                                      Default: ${params.max_cpus}

    Other options:
      --outdir [file]                 The output directory where the results will be saved.
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move
                                      Default: copy
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits.
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful.
      --plaintext_email [bool]        Send plain-text email instead of HTML.
      --max_multiqc_email_size [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached
                                      Default: 25MB
      --monochrome_logs [bool]        Do not use coloured log outputs.
      --multiqc_config [str]          Custom config file to supply to MultiQC.
      --tracedir [str]                Directory to keep pipeline Nextflow logs and reports.
                                      Default: "${params.outdir}/pipeline_info"
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch.
      --awsregion [str]               The AWS Region for your AWS Batch job to run on.
      --awscli [str]                  Path to the AWS CLI tool.
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
// Validate inputs
params.input ?: params.input_paths ?: { log.error "No read data provided. Make sure you have used the '--input' option."; exit 1 }()
(params.seqtype == 'rna' || params.seqtype == 'dna') ?: { log.error "No or incorrect sequence type provided, you need to add '--seqtype 'dna'' or '--seqtype 'rna''."; exit 1 }()

// Set mapping index base name according to sequencing type
base_index_name = params.base_index_name ?  params.base_index_name :  "hla_reference_${params.seqtype}"

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$baseDir/docs/images/", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if( params.input_paths ){
    if( params.single_end || params.bam) {
        Channel
            .from( params.input_paths )
            .map { row -> [ row[0], [ file( row[1][0], checkIfExists: true ) ] ] }
            .ifEmpty { exit 1, "params.input_paths or params.bams was empty - no input files supplied!" }
            .set { input_data }
    } else {
        Channel
            .from( params.input_paths )
            .map { row -> [ row[0], [ file( row[1][0], checkIfExists: true), file( row[1][1], checkIfExists: true) ] ] }
            .ifEmpty { exit 1, "params.input_paths or params.bams was empty - no input files supplied!" }
            .set { input_data }
        }
} else if (!params.bam){
    Channel
    .fromFilePairs( params.input, size: params.single_end ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.input}\nNB: Path needs" +
    "to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --single_end on the command line." }
    .set { input_data }
} else {
    Channel
    .fromPath( params.input )
    .map { row -> [ file(row).baseName, [ file( row, checkIfExists: true ) ] ] }
    .ifEmpty { exit 1, "Cannot find any bam file matching: ${params.input}\nNB: Path needs" +
    "to be enclosed in quotes!\n" }
    .dump() //For debugging purposes
    .set { input_data }
}

if( params.bam ) log.info "BAM file format detected. Initiate remapping to HLA alleles with yara mapper."

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['File Type']        = params.bam ? 'BAM' : 'Other (fastq, fastq.gz, ...)'
summary['Seq Type']         = params.seqtype
summary['Index Location']   = "$params.base_index_path/$base_index_name"
summary['IP Solver']        = params.solver
summary['Enumerations']     = params.enumerations
summary['Beta']             = params.beta
summary['Max Memory']       = params.max_memory
summary['Max CPUs']         = params.max_cpus
summary['Max Time']         = params.max_time
summary['Input']            = params.input_paths ? params.input_paths : params.input
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Output Dir']       = params.outdir
summary['Launch Dir']       = workflow.launchDir
summary['Working Dir']      = workflow.workDir
summary['Script Dir']       = workflow.projectDir
summary['User']             = workflow.userName
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on Failure'] = params.email_on_fail
    summary['MultiQC Maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-hlatyping-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/hlatyping Workflow Summary'
    section_href: 'https://github.com/nf-core/hlatyping'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

if( params.bam ) log.info "BAM file format detected. Initiate remapping to HLA alleles with yara mapper."

/*
 * Preparation - Unpack files if packed.
 *
 * OptiType cannot handle *.gz archives as input files,
 * So we have to unpack first, if this is the case.
 */
if ( !params.bam  ) { // FASTQ files processing
    process unzip {

        input:
        set val(pattern), file(reads) from input_data

        output:
        set val(pattern), "unzipped_{1,2}.fastq" into raw_reads

        script:
        if(params.single_end)
            """
            zcat ${reads[0]} > unzipped_1.fastq
            """
        else
            """
            zcat ${reads[0]} > unzipped_1.fastq
            zcat ${reads[1]} > unzipped_2.fastq
            """
    }
} else { // BAM files processing

    /*
     * Preparation - Remapping of reads against HLA reference and filtering these
     *
     * In case the user provides BAM files, a remapping step
     * is then done against the HLA reference sequence.
     */
    process remap_to_hla {
        label 'process_medium'

        input:
        path(data_index) from params.base_index_path
        set val(pattern), file(bams) from input_data
        output:
        set val(pattern), "mapped_{1,2}.bam" into fished_reads

        script:
        def full_index = "$data_index/$base_index_name"
        if (params.single_end)
            """
            samtools bam2fq $bams > output_1.fastq
            yara_mapper -e 3 -t ${task.cpus} -f bam $full_index output_1.fastq > output_1.bam
            samtools view -@ ${task.cpus} -h -F 4 -b1 output_1.bam > mapped_1.bam
            """
        else
            """
            samtools view -@ ${task.cpus} -h -f 0x40 $bams > output_1.bam
            samtools view -@ ${task.cpus} -h -f 0x80 $bams > output_2.bam
            samtools bam2fq output_1.bam > output_1.fastq
            samtools bam2fq output_2.bam > output_2.fastq
            yara_mapper -e 3 -t ${task.cpus} -f bam $full_index output_1.fastq output_2.fastq > output.bam
            samtools view -@ ${task.cpus} -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
            samtools view -@ ${task.cpus} -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
            """
    }
}


/*
 * STEP 1 - Create config.ini for Optitype
 *
 * Optitype requires a config.ini file with information like
 * which solver to use for the optimization step. Also, the number
 * of threads is specified there for different steps.
 * As we do not want to touch the original source code of Optitype,
 * we simply take information from Nextflow about the available resources
 * and create a small config.ini as first stepm which is then passed to Optitype.
 */
process make_ot_config {
    publishDir "${params.outdir}/config", mode: params.publish_dir_mode

    output:
    file 'config.ini' into config

    script:
    """
    configbuilder --max-cpus ${params.max_cpus} --solver ${params.solver} > config.ini
    """
}

/*
 * Preparation Step - Pre-mapping against HLA
 *
 * In order to avoid the internal usage of RazerS from within OptiType when
 * the input files are of type `fastq`, we perform a pre-mapping step
 * here with the `yara` mapper, and map against the HLA reference only.
 *
 */
if (!params.bam)
    process pre_map_hla {
        label 'process_medium'

        input:
        path(data_index) from params.base_index_path
        set val(pattern), file(reads) from raw_reads

        output:
        set val(pattern), "mapped_{1,2}.bam" into fished_reads

        script:
        def full_index = "$data_index/$base_index_name"
        if (params.single_end)
            """
            yara_mapper -e 3 -t ${task.cpus} -f bam $full_index $reads > output_1.bam
            samtools view -@ ${task.cpus} -h -F 4 -b1 output_1.bam > mapped_1.bam
            """
        else
            """
            yara_mapper -e 3 -t ${task.cpus} -f bam $full_index $reads > output.bam
            samtools view -@ ${task.cpus} -h -F 4 -f 0x40 -b1 output.bam > mapped_1.bam
            samtools view -@ ${task.cpus} -h -F 4 -f 0x80 -b1 output.bam > mapped_2.bam
            """
    }

/*
 * STEP 2 - Run Optitype
 *
 * This is the major process, that formulates the IP and calls the selected
 * IP solver.
 *
 * Ouput formats: <still to enter>
 */
process run_optitype {
    publishDir "${params.outdir}/optitype/", mode: params.publish_dir_mode

    input:
    file 'config.ini' from config
    set val(pattern), file(reads) from fished_reads

    output:
    file "${pattern}"

    script:
    """
    OptiTypePipeline.py -i ${reads} -e ${params.enumerations} -b ${params.beta} \\
        -p "${pattern}" -c config.ini --${params.seqtype} --outdir ${pattern}
    """
}

/*
 *
 * Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file output_docs from ch_output_docs
    file images from ch_output_docs_images

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    multiqc --version &> v_multiqc.txt 2>&1 || true
    samtools --version &> v_samtools.txt 2>&1 || true
    yara_mapper --help  &> v_yara.txt 2>&1 || true
    cat \$(which OptiTypePipeline.py) &> v_optitype.txt 2>&1 || true
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: params.publish_dir_mode

    input:
    file (multiqc_config) from ch_multiqc_config
    file mqc_custom_config from ch_multiqc_custom_config.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    """
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}

/*
* Completion e-mail notification
*/
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/hlatyping] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/hlatyping] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/hlatyping] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/hlatyping] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/hlatyping] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/hlatyping] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/hlatyping]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/hlatyping]${c_red} Pipeline completed with errors${c_reset}-"
    }
}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/hlatyping v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
